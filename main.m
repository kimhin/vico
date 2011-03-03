#include <sys/types.h>
#include <sys/ptrace.h>

#include <signal.h>

#include "log.h"

#include <pthread.h>
pthread_mutex_t onig_mutex = PTHREAD_MUTEX_INITIALIZER;

int
main(int argc, char *argv[])
{
	LogLevel ll = SYSLOG_LEVEL_DEBUG1 + 2;
	log_init(argv[0], ll, SYSLOG_FACILITY_USER, 1);
#if defined(RELEASE_BUILD)
	ptrace(PT_DENY_ATTACH, 0, 0, 0);
#endif

	signal(SIGPIPE, SIG_IGN);
	return NSApplicationMain(argc, (const char **) argv);
}
