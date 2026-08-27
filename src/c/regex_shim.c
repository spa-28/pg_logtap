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

// errbuf (may be NULL) receives regerror's text for the failure — regerror
// must run while r->re still holds the failed compile's state, i.e. BEFORE
// free. A NULL calloc return has no regex state to describe: the caller's
// fixed "out of memory" text covers it.
lt_regex *lt_regex_compile(const char *pattern, char *errbuf, size_t errlen) {
    lt_regex *r = calloc(1, sizeof(lt_regex));
    if (r == NULL) return NULL;
    int rc = regcomp(&r->re, pattern, REG_EXTENDED | REG_NOSUB);
    if (rc != 0) {
        if (errbuf != NULL && errlen > 0) regerror(rc, &r->re, errbuf, errlen);
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

// Sub-expression variant for redaction: compiled without REG_NOSUB so
// regexec reports the match span.
lt_regex *lt_regex_compile_sub(const char *pattern, char *errbuf, size_t errlen) {
    lt_regex *r = calloc(1, sizeof(lt_regex));
    if (r == NULL) return NULL;
    int rc = regcomp(&r->re, pattern, REG_EXTENDED);
    if (rc != 0) {
        if (errbuf != NULL && errlen > 0) regerror(rc, &r->re, errbuf, errlen);
        free(r);
        return NULL;
    }
    return r;
}

// First match in s as (start,end) byte offsets from s; 1 = no match. notbol
// keeps '^' anchored to the true string start when scanning resumes
// mid-string (REG_NOTBOL is in POSIX).
int lt_regex_find(const lt_regex *r, const char *s, int notbol,
                  size_t *start, size_t *end) {
    regmatch_t m[1];
    if (regexec(&r->re, s, 1, m, notbol ? REG_NOTBOL : 0) != 0) return 1;
    *start = (size_t) m[0].rm_so;
    *end = (size_t) m[0].rm_eo;
    return 0;
}
