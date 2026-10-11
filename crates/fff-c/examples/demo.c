#include <fff.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    struct FffCreateOptions opts;
    memset(&opts, 0, sizeof(opts));
    opts.version = FFF_CREATE_OPTIONS_VERSION;
    opts.base_path = ".";

    struct FffResult *res = fff_create_instance_with(&opts);
    if (!res) {
        fprintf(stderr, "fff_create_instance_with returned NULL\n");
        return 1;
    }
    if (!res->success) {
        fprintf(stderr, "fff_create_instance_with failed: %s\n", res->error ? res->error : "unknown error");
        fff_free_result(res);
        return 1;
    }

    void *handle = res->handle;
    fff_free_result(res);

    /* Test basic search */
    struct FffResult *search_res = fff_search(handle, "Cargo", NULL, 1, 0, 10, 100, 3);
    if (search_res) {
        if (search_res->success) {
            struct FffSearchResult *sr = (struct FffSearchResult *)search_res->handle;
            printf("fff search succeeded: matched %u files\n", sr ? sr->count : 0);
            if (sr) {
                fff_free_search_result(sr);
            }
        }
        fff_free_result(search_res);
    }

    fff_destroy(handle);
    printf("Demo finished successfully.\n");
    return 0;
}
