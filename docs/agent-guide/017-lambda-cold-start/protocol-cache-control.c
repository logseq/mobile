#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <time.h>
#include <stdio.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
static void dump_cache_state(void) {
    bool (*overridden)(void) = (bool (*)(void))dlsym(RTLD_DEFAULT, "dyld_shared_cache_some_image_overridden");
    printf("DYLD_SHARED_CACHE_OVERRIDDEN %s\n", overridden ? (overridden() ? "true" : "false") : "unavailable");
    unsigned long total = 0;
    for (unsigned int i=0; i<_dyld_image_count(); i++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        unsigned long bytes = 0;
        getsectiondata(header, "__TEXT", "__swift5_proto", &bytes);
        if (bytes) printf("PROTOCOL_SECTION %lu %s\n", bytes/4, _dyld_get_image_name(i));
        total += bytes/4;
    }
    printf("PROTOCOL_SECTION_TOTAL %lu\n",total);

}

void logseq_register_cache_dump(void) { atexit(dump_cache_state); }
