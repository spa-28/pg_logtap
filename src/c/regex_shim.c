// regex_t owner: its layout is libc- and arch-specific (glibc's even has
// bitfields, which translate-c renders opaque), so the buffer lives here in
// C — compiled by zig cc against the TARGET libc's <regex.h> — and Zig holds
// only an opaque box. The previous fixed 64-byte reservation in Zig (glibc
// x86-64) was stack corruption wherever the target's regex_t was larger.
#include <regex.h>
#include <stdlib.h>

typedef struct {
    regex_t re; // the real size, whatever the target libc says
} lt_regex;

lt_regex *lt_regex_compile(const char *pattern) {
    lt_regex *r = calloc(1, sizeof(lt_regex));
    if (r == NULL) return NULL;
    if (regcomp(&r->re, pattern, REG_EXTENDED | REG_NOSUB) != 0) {
        free(r);
        return NULL;
    }
    return r;
}

void lt_regex_free(lt_regex *r) {
    if (r == NULL) return;
    regfree(&r->re);
    free(r);
}

int lt_regex_matches(const lt_regex *r, const char *s) {
    return regexec(&r->re, s, 0, NULL, 0) == 0;
}
