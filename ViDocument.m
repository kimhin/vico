#import "ViDocument.h"
#import "ViDocumentView.h"
#import "ExTextView.h"
#import "ViLanguageStore.h"
#import "NSTextStorage-additions.h"

#import "NoodleLineNumberView.h"
#import "NoodleLineNumberMarker.h"
#import "MarkerLineNumberView.h"

BOOL makeNewWindowInsteadOfTab = NO;

@interface ViDocument (internal)
- (ViWindowController *)windowController;
@end

@implementation ViDocument

@synthesize symbols;
@synthesize filteredSymbols;

- (id)init
{
	self = [super init];
	if (self)
	{
		symbols = [NSArray array];
		views = [[NSMutableArray alloc] init];
	}
	return self;
}

#pragma mark -
#pragma mark NSDocument interface

- (void)makeWindowControllers
{
	if (makeNewWindowInsteadOfTab)
	{
		windowController = [[ViWindowController alloc] init];
		makeNewWindowInsteadOfTab = NO;
	}
	else
	{
		windowController = [ViWindowController currentWindowController];
	}

	[self addWindowController:windowController];
	[windowController addNewTab:self];
}

- (ViDocumentView *)makeView
{
	/*
	if ([views count] > 0)
		return [views objectAtIndex:0];
	*/

	ViDocumentView *documentView = [[ViDocumentView alloc] init];
	[NSBundle loadNibNamed:@"ViDocument" owner:documentView];
	ViTextView *textView = [documentView textView];
	[views addObject:documentView];
	INFO(@"now %u views", [views count]);

	if ([views count] == 1)
	{
		// this is the first view
		[textView setString:readContent];
		readContent = nil;
		textStorage = [textView textStorage];
	}
	else
	{
		// alternative views, make them share the same text storage
		[[textView layoutManager] replaceTextStorage:textStorage];
	}
	[textStorage setDelegate:self];
	[textView initEditorWithDelegate:self documentView:documentView];

	[self configureSyntax];
	[self enableLineNumbers:[[NSUserDefaults standardUserDefaults] boolForKey:@"number"] forScrollView:[textView enclosingScrollView]];

	return documentView;
#if 0
	NSRect frame = [textView frame];
	NSScrollView *cloneScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, 100)];

	NSTextContainer *container = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(frame.size.width, 1e100)];
	NSLayoutManager *lm = [[NSLayoutManager alloc] init];
	[lm addTextContainer:container];
	[[textView textStorage] addLayoutManager:lm];
	ViTextView *cloneView = [[ViTextView alloc] initWithFrame:NSMakeRect(0, 0, 0, 0) textContainer:container];
	[cloneView initEditorWithDelegate:self];
	[cloneView configureForURL:[self fileURL]];

	NSClipView *cloneClip = [[NSClipView alloc] initWithFrame:NSMakeRect(0, 0, 0, 0)];
	[cloneClip setDocumentView:cloneView];
	[cloneScroll setContentView:cloneClip];
	[cloneScroll setHasVerticalScroller:YES];
	[cloneScroll setHasHorizontalScroller:YES];
	[cloneScroll setAutohidesScrollers:YES];
	[cloneScroll setHasVerticalRuler:YES];
	[cloneScroll setRulersVisible:YES];
	[self enableLineNumbers:[[NSUserDefaults standardUserDefaults] boolForKey:@"number"] forScrollView:cloneScroll];

	[documentSplit addSubview:cloneScroll];
#endif
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
	return [[textStorage string] dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError
{
	readContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	return YES;
}

- (void)setFileURL:(NSURL *)absoluteURL
{
	[super setFileURL:absoluteURL];
	if (textStorage)
		[self configureSyntax];
}
#pragma mark -
#pragma mark Syntax parsing

- (void)applySyntaxResult:(ViSyntaxContext *)context
{
	ViDocumentView *dv;
	for (dv in views)
	{
		[dv applySyntaxResult:context];
	}
}

- (void)highlightEverything
{
	if (language == nil)
	{
		ViDocumentView *dv;
		for (dv in views)
			[dv resetAttributesInRange:NSMakeRange(0, [textStorage length])];
		return;
	}

	NSInteger endLocation = [textStorage locationForStartOfLine:10];
	if (endLocation == -1)
		endLocation = [textStorage length];

	[self dispatchSyntaxParserWithRange:NSMakeRange(0, endLocation) restarting:NO];
}

- (void)performContext:(ViSyntaxContext *)ctx
{
	NSRange range = ctx.range;
	unichar *chars = malloc(range.length * sizeof(unichar));
	DEBUG(@"allocated %u bytes characters %p", range.length * sizeof(unichar), chars);
	[[textStorage string] getCharacters:chars range:range];

	ctx.characters = chars;
	unsigned startLine = ctx.lineOffset;

	// unsigned endLine = [self lineNumberAtLocation:NSMaxRange(range) - 1];
	// INFO(@"parsing line %u -> %u (ctx = %@)", startLine, endLine, ctx);

	[syntaxParser parseContext:ctx];
	[self performSelector:@selector(applySyntaxResult:) withObject:ctx afterDelay:0.0];

	if (ctx.lineOffset > startLine)
	{
		// INFO(@"line endings have changed at line %u", endLine);
		
		if (nextContext && nextContext != ctx)
		{
			if (nextContext.lineOffset < startLine)
			{
				DEBUG(@"letting previous scheduled parsing from line %u continue", nextContext.lineOffset);
				return;
			}
			DEBUG(@"cancelling scheduled parsing from line %u (nextContext = %@)", nextContext.lineOffset, nextContext);
			[nextContext setCancelled:YES];
		}
		
		nextContext = ctx;
		[self performSelector:@selector(restartContext:) withObject:ctx afterDelay:0.0025];
	}
	// FIXME: probably need a stack here
}

- (void)dispatchSyntaxParserWithRange:(NSRange)aRange restarting:(BOOL)flag
{
	if (aRange.length == 0)
		return;

	unsigned line = [textStorage lineNumberAtLocation:aRange.location];
	DEBUG(@"dispatching from line %u", line);
	ViSyntaxContext *ctx = [[ViSyntaxContext alloc] initWithLine:line];
	ctx.range = aRange;
	ctx.restarting = flag;

	[self performContext:ctx];
}

- (void)restartContext:(ViSyntaxContext *)context
{
	nextContext = nil;

	if (context.cancelled)
	{
		DEBUG(@"context %@, from line %u, is cancelled", context, context.lineOffset);
		return;
	}

	NSUInteger startLocation = [textStorage locationForStartOfLine:context.lineOffset];
	NSInteger endLocation = [textStorage locationForStartOfLine:context.lineOffset + 10];
	if (endLocation == -1)
		endLocation = [textStorage length];

	context.range = NSMakeRange(startLocation, endLocation - startLocation);
	DEBUG(@"restarting parse context at line %u, range %@", startLocation, NSStringFromRange(context.range));
	[self performContext:context];
}

- (void)setLanguageFromString:(NSString *)aLanguage
{
	ViLanguage *newLanguage = nil;
	bundle = [[ViLanguageStore defaultStore] bundleForLanguage:aLanguage language:&newLanguage];
	[newLanguage patterns];
	if (newLanguage != language)
	{
		language = newLanguage;
		syntaxParser = [[ViSyntaxParser alloc] initWithLanguage:language];
		[self highlightEverything];
	}
}

- (void)configureForURL:(NSURL *)aURL
{
	ViLanguage *newLanguage = nil;
	if (aURL)
	{
		NSString *firstLine = nil;
		NSUInteger eol;
		[[textStorage string] getLineStart:NULL end:NULL contentsEnd:&eol forRange:NSMakeRange(0, 0)];
		if (eol > 0)
			firstLine = [[textStorage string] substringWithRange:NSMakeRange(0, eol)];

		bundle = nil;
		if ([firstLine length] > 0)
			bundle = [[ViLanguageStore defaultStore] bundleForFirstLine:firstLine language:&newLanguage];
		if (bundle == nil)
			bundle = [[ViLanguageStore defaultStore] bundleForFilename:[aURL path] language:&newLanguage];
	}

	if (bundle == nil)
	{
		bundle = [[ViLanguageStore defaultStore] defaultBundleLanguage:&newLanguage];
	}

	INFO(@"new language = %@, (%@)", newLanguage, language);

	[newLanguage patterns];
	if (newLanguage != language)
	{
		language = newLanguage;
		syntaxParser = [[ViSyntaxParser alloc] initWithLanguage:language];
		[self highlightEverything];
	}
}

- (void)configureSyntax
{
	/* update syntax definition */
	NSDictionary *syntaxOverride = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"syntaxOverride"];
	NSString *syntax = [syntaxOverride objectForKey:[[self fileURL] path]];
	if (syntax)
		[self setLanguageFromString:syntax];
	else
		[self configureForURL:[self fileURL]];
	// [languageButton selectItemWithTitle:[[textView language] displayName]];
}

- (void)pushContinuationsFromLocation:(NSUInteger)aLocation string:(NSString *)aString forward:(BOOL)flag
{
	int n = 0;
	NSInteger i = 0;

        while (i < [aString length])
        {
		NSUInteger eol, end;
		[aString getLineStart:NULL end:&end contentsEnd:&eol forRange:NSMakeRange(i, 0)];
		if (end == eol)
			break;
		n++;
		i = end;
        }

	if (n == 0)
		return;

	unsigned lineno = 0;
	if (aLocation > 1)
		lineno = [textStorage lineNumberAtLocation:aLocation - 1];

	if (flag)
		[syntaxParser pushContinuations:[NSValue valueWithRange:NSMakeRange(lineno, n)]];
	else
		[syntaxParser pullContinuations:[NSValue valueWithRange:NSMakeRange(lineno, n)]];
}

#pragma mark -
#pragma mark NSTextStorage delegate method

- (BOOL)textView:(NSTextView *)aTextView shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString
{
	INFO(@"range = %@, replacement = [%@]", NSStringFromRange(affectedCharRange), replacementString);
	if (affectedCharRange.length == 0)
	{
		[self pushContinuationsFromLocation:affectedCharRange.location string:replacementString forward:YES];
	}
	else if ([replacementString length] == 0)
	{
		[self pushContinuationsFromLocation:affectedCharRange.location
		                             string:[[textStorage string] substringWithRange:affectedCharRange]
		                            forward:NO];
	}

	return YES;
}

- (void)textStorageDidProcessEditing:(NSNotification *)notification
{
	if (ignoreEditing)
	{
		ignoreEditing = NO;
		return;
	}

	NSRange area = [textStorage editedRange];
	INFO(@"got notification for changes in area %@, change length = %i, storage = %p, self = %@",
		NSStringFromRange(area), [textStorage changeInLength],
		textStorage, self);

	if (language == nil)
	{
		ViDocumentView *dv;
		for (dv in views)
			[dv resetAttributesInRange:area];
		return;
	}
	
	// extend our range along line boundaries.
	NSUInteger bol, eol;
	[[textStorage string] getLineStart:&bol end:&eol contentsEnd:NULL forRange:area];
	area.location = bol;
	area.length = eol - bol;
	DEBUG(@"extended area to %@", NSStringFromRange(area));

	[self dispatchSyntaxParserWithRange:area restarting:NO];
}

#pragma mark -
#pragma mark Line numbers

- (void)enableLineNumbers:(BOOL)flag forScrollView:(NSScrollView *)aScrollView
{
	if (flag)
	{
		NoodleLineNumberView *lineNumberView = [[MarkerLineNumberView alloc] initWithScrollView:aScrollView];
		[aScrollView setVerticalRulerView:lineNumberView];
		[aScrollView setHasHorizontalRuler:NO];
		[aScrollView setHasVerticalRuler:YES];
		[aScrollView setRulersVisible:YES];
	}
	else
		[aScrollView setRulersVisible:NO];
}

- (void)enableLineNumbers:(BOOL)flag
{
	// enable line numbers for all textviews
}

- (IBAction)toggleLineNumbers:(id)sender
{
	ViDocumentView *dv;
	for (dv in views)
	{
		[self enableLineNumbers:[sender state] == NSOffState forScrollView:[[dv textView] enclosingScrollView]];
	}
}


#pragma mark -
#pragma mark Other interesting stuff

- (void)changeTheme:(ViTheme *)theme
{
	ViDocumentView *dv;
	for (dv in views)
	{
		[[dv textView] setTheme:theme];
		[dv reapplyTheme];
	}
}

- (void)setPageGuide:(int)pageGuideValue
{
	ViDocumentView *dv;
	for (dv in views)
	{
		[[dv textView] setPageGuide:pageGuideValue];
	}
}

#pragma mark -
#pragma mark ViTextView delegate methods

- (void)message:(NSString *)fmt, ...
{
	va_list ap;
	va_start(ap, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);

	[[windowController statusbar] setStringValue:msg];
}

- (IBAction)finishedExCommand:(id)sender
{
	NSString *exCommand = [[windowController statusbar] stringValue];
	INFO(@"got ex command [%@]", exCommand);
	[[windowController statusbar] setStringValue:@""];
	[[windowController statusbar] setEditable:NO];
	[[[self windowController] window] makeFirstResponder:exCommandView];
	if ([exCommand length] > 0)
		[exCommandView performSelector:exCommandSelector withObject:exCommand];
	exCommandView = nil;
}

- (void)getExCommandForTextView:(ViTextView *)aTextView selector:(SEL)aSelector prompt:(NSString *)aPrompt
{
	[[windowController statusbar] setStringValue:aPrompt];
	[[windowController statusbar] setEditable:YES];
	[[windowController statusbar] setDelegate:self];
	[[windowController statusbar] setAction:@selector(finishedExCommand:)];
	exCommandSelector = aSelector;
	exCommandView = aTextView;
	[[[self windowController] window] makeFirstResponder:[windowController statusbar]];
}

- (void)getExCommandForTextView:(ViTextView *)aTextView selector:(SEL)aSelector
{
	[self getExCommandForTextView:aTextView selector:aSelector prompt:@":"];
}

- (BOOL)findPattern:(NSString *)pattern
	    options:(unsigned)find_options
         regexpType:(int)regexpSyntax
{
	return [(ViTextView *)[[views objectAtIndex:0] textView] findPattern:pattern options:find_options regexpType:regexpSyntax];
}

// tag push
- (void)pushLine:(NSUInteger)aLine column:(NSUInteger)aColumn
{
	[[[self windowController] sharedTagStack] pushFile:[[self fileURL] path] line:aLine column:aColumn];
}

- (void)popTag
{
	NSDictionary *location = [[[self windowController] sharedTagStack] pop];
	if (location == nil)
	{
		[self message:@"The tags stack is empty"];
		return;
	}

	NSString *file = [location objectForKey:@"file"];
	ViDocument *document = [[NSDocumentController sharedDocumentController]
		openDocumentWithContentsOfURL:[NSURL fileURLWithPath:file] display:YES error:nil];

	if (document)
	{
		[[self windowController] selectDocument:document];
		[(ViTextView *)[[views objectAtIndex:0] textView] gotoLine:[[location objectForKey:@"line"] unsignedIntegerValue]
				                                    column:[[location objectForKey:@"column"] unsignedIntegerValue]];
	}
}

#pragma mark -

- (ViWindowController *)windowController
{
	return [[self windowControllers] objectAtIndex:0];
}

- (void)canCloseDocumentWithDelegate:(id)aDelegate shouldCloseSelector:(SEL)shouldCloseSelector contextInfo:(void *)contextInfo
{
	[super canCloseDocumentWithDelegate:self shouldCloseSelector:@selector(document:shouldClose:contextInfo:) contextInfo:contextInfo];
}

- (void)document:(NSDocument *)doc shouldClose:(BOOL)shouldClose contextInfo:(void *)contextInfo
{
	if (shouldClose)
	{
		INFO(@"closing document");
		// [windowController closeDocument:self];
		[self close];
#if 0
		if ([windowController numberOfTabViewItems] == 0)
		{
			/* Close the window after all tabs are gone. */
			[[windowController window] performClose:self];
		}
#endif
	}
}

- (IBAction)setLanguage:(id)sender
{
	INFO(@"sender = %@, title = %@", sender, [sender title]);

	[self setLanguageFromString:[sender title]];
	if (language && [self fileURL])
	{
		NSMutableDictionary *syntaxOverride = [NSMutableDictionary dictionaryWithDictionary:
			[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"syntaxOverride"]];
		[syntaxOverride setObject:[sender title] forKey:[[self fileURL] path]];
		[[NSUserDefaults standardUserDefaults] setObject:syntaxOverride forKey:@"syntaxOverride"];
	}
}

#pragma mark -
#pragma mark Symbol List

- (void)goToSymbol:(ViSymbol *)aSymbol
{
	NSRange range = [aSymbol range];
	ViTextView *firstTextView = (ViTextView *)[[views objectAtIndex:0] textView];
	[firstTextView setCaret:range.location];
	[firstTextView scrollRangeToVisible:range];
	[[[self windowController] window] makeFirstResponder:firstTextView];
	[firstTextView showFindIndicatorForRange:range];
}

- (NSUInteger)filterSymbols:(ViRegexp *)rx
{
	NSMutableArray *fs = [[NSMutableArray alloc] initWithCapacity:[symbols count]];
	ViSymbol *s;
	for (s in symbols)
	{
		if ([rx matchInString:[s symbol]])
		{
			[fs addObject:s];
		}
	}
	[self setFilteredSymbols:fs];
	return [fs count];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"ViDocument: %@", [self displayName]];
}

- (void)setMostRecentDocumentView:(ViDocumentView *)docView
{
	[windowController setMostRecentDocument:self view:docView];
}

@end

