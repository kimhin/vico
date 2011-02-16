#import "ViTextStorage.h"
#include "logging.h"

@implementation ViTextStorage

static NSMutableCharacterSet *wordSet = nil;

#pragma mark -
#pragma mark Primitive methods

/*
 * http://developer.apple.com/library/mac/#documentation/Cocoa/Conceptual/TextStorageLayer/Tasks/Subclassing.html
 */

- (id)init
{
	self = [super init];
	if (self) {
		string = [[NSMutableString alloc] init];
		typingAttributes = [NSDictionary dictionaryWithObject:[NSFont userFixedPitchFontOfSize:20]
		                                               forKey:NSFontAttributeName];
	}
	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<ViTextStorage %p>", self];
}

- (NSString *)string
{
	return string;
}

- (void)replaceCharactersInRange:(NSRange)aRange withString:(NSString *)str
{
	[string replaceCharactersInRange:aRange withString:str];

	NSInteger lengthChange = [str length] - aRange.length;
	[self edited:NSTextStorageEditedCharacters range:aRange changeInLength:lengthChange];
}

- (void)insertString:(NSString *)aString atIndex:(NSUInteger)anIndex
{
	[string insertString:aString atIndex:anIndex];
	[self edited:NSTextStorageEditedCharacters range:NSMakeRange(anIndex, 0) changeInLength:[aString length]];
}

- (NSDictionary *)attributesAtIndex:(unsigned)anIndex effectiveRange:(NSRangePointer)aRangePtr
{
	if (aRangePtr)
		*aRangePtr = NSMakeRange(0, [string length]);
	return typingAttributes;
}

- (void)setAttributes:(NSDictionary *)attributes range:(NSRange)range
{
	/* We always use the typing attributes. */
}

- (void)setTypingAttributes:(NSDictionary *)attributes
{
	typingAttributes = [attributes copy];
	[self edited:NSTextStorageEditedAttributes range:NSMakeRange(0, [self length]) changeInLength:0];
}

#pragma mark -
#pragma mark Line number handling

- (NSInteger)locationForStartOfLine:(NSUInteger)aLineNumber
{
	int line = 1;
	NSInteger location = 0;
	while (line < aLineNumber) {
		NSUInteger end;
		[[self string] getLineStart:NULL
                                        end:&end
                                contentsEnd:NULL
                                   forRange:NSMakeRange(location, 0)];
		if (location == end)
			return -1;
		location = end;
		line++;
	}
	
	return location;
}

- (NSUInteger)lineNumberAtLocation:(NSUInteger)aLocation
{
	int line = 1;
	NSUInteger location = 0;
	if (aLocation > [self length])
		aLocation = [self length];
	while (location < aLocation) {
		NSUInteger bol, end;
		[[self string] getLineStart:&bol
		                        end:&end
		                contentsEnd:NULL
		                   forRange:NSMakeRange(location, 0)];
		if (end > aLocation)
			break;
		location = end;
		line++;
	}

	return line;
}

- (NSUInteger)lineCount
{
	return [self lineNumberAtLocation:NSUIntegerMax];
}

- (void)processEditing
{
	/* Update our line number data structure. */

	[super processEditing];
}

#pragma mark -
#pragma mark Convenience methods

- (NSUInteger)skipCharactersInSet:(NSCharacterSet *)characterSet
                             from:(NSUInteger)startLocation
                               to:(NSUInteger)toLocation
                         backward:(BOOL)backwardFlag
{
	NSRange r;
	if (backwardFlag)
		r = NSMakeRange(toLocation, startLocation - toLocation + 1);
	else
		r = NSMakeRange(startLocation, toLocation - startLocation);

	r = [[self string] rangeOfCharacterFromSet:[characterSet invertedSet]
					   options:backwardFlag ? NSBackwardsSearch : 0
					     range:r];

	if (r.location == NSNotFound)
		return toLocation;
	return r.location;
}

- (NSUInteger)skipCharactersInSet:(NSCharacterSet *)characterSet
                     fromLocation:(NSUInteger)startLocation
                         backward:(BOOL)backwardFlag
{
	return [self skipCharactersInSet:characterSet
				    from:startLocation
				      to:backwardFlag ? 0 : [self length]
				backward:backwardFlag];
}

- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation
                      toLocation:(NSUInteger)toLocation
{
	return [self skipCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
				    from:startLocation
				      to:toLocation
				backward:NO];
}

- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation
{
	return [self skipCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
			    fromLocation:startLocation
				backward:NO];
}

- (NSString *)wordAtLocation:(NSUInteger)aLocation range:(NSRange *)returnRange
{
	if (aLocation >= [self length]) {
		if (returnRange != nil)
			*returnRange = NSMakeRange(0, 0);
		return @"";
	}

	if (wordSet == nil) {
		wordSet = [NSMutableCharacterSet characterSetWithCharactersInString:@"_"];
		[wordSet formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
	}

	NSUInteger word_start = [self skipCharactersInSet:wordSet fromLocation:aLocation backward:YES];
	if (word_start < aLocation && word_start > 0)
		word_start += 1;

	NSUInteger word_end = [self skipCharactersInSet:wordSet fromLocation:aLocation backward:NO];
	if (word_end > word_start) {
		NSRange range = NSMakeRange(word_start, word_end - word_start);
		if (returnRange)
			*returnRange = range;
		return [[self string] substringWithRange:range];
	}

	if (returnRange)
		*returnRange = NSMakeRange(0, 0);

	return nil;
}

- (NSString *)wordAtLocation:(NSUInteger)aLocation
{
	return [self wordAtLocation:aLocation range:nil];
}

- (NSUInteger)lineIndexAtLocation:(NSUInteger)aLocation
{
	NSUInteger bol, end;
	[[self string] getLineStart:&bol end:&end contentsEnd:NULL forRange:NSMakeRange(aLocation, 0)];
	return aLocation - bol;
}

- (NSUInteger)columnAtLocation:(NSUInteger)aLocation
{
	NSUInteger bol, end;
	[[self string] getLineStart:&bol end:&end contentsEnd:NULL forRange:NSMakeRange(aLocation, 0)];
	NSUInteger c = 0, i;
	int ts = [[NSUserDefaults standardUserDefaults] integerForKey:@"tabstop"];
	for (i = bol; i <= aLocation && i < end; i++) {
		unichar ch = [[self string] characterAtIndex:i];
		if (ch == '\t')
			c += ts - (c % ts);
		else
			c++;
	}
	return c;
}

- (NSUInteger)locationForColumn:(NSUInteger)column
                   fromLocation:(NSUInteger)aLocation
                      acceptEOL:(BOOL)acceptEOL
{
	NSUInteger bol, eol;
	[[self string] getLineStart:&bol end:NULL contentsEnd:&eol forRange:NSMakeRange(aLocation, 0)];
	NSUInteger c = 0, i;
	int ts = [[NSUserDefaults standardUserDefaults] integerForKey:@"tabstop"];
	for (i = bol; i < eol; i++) {
		unichar ch = [[self string] characterAtIndex:i];
		if (ch == '\t')
			c += ts - (c % ts);
		else
			c++;
		if (c >= column)
			break;
	}
	if (!acceptEOL && i == eol && bol < eol)
		i = eol - 1;
	return i;
}

- (NSString *)lineForLocation:(NSUInteger)aLocation
{
	NSUInteger bol, eol;
	[[self string] getLineStart:&bol end:NULL contentsEnd:&eol forRange:NSMakeRange(aLocation, 0)];
	return [[self string] substringWithRange:NSMakeRange(bol, eol - bol)];
}

- (BOOL)isBlankLineAtLocation:(NSUInteger)aLocation
{
	NSString *line = [self lineForLocation:aLocation];
	return [line rangeOfCharacterFromSet:[[NSCharacterSet whitespaceCharacterSet] invertedSet]].location == NSNotFound;
}

@end
