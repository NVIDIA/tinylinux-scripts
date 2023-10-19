/*
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-FileCopyrightText: Copyright (c) 2023, NVIDIA CORPORATION.  All rights reserved.
 * See LICENSE file for details.
 */

#include <ctype.h>
#include <fnmatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

int main(int argc, char* argv[])
{
    static struct utsname uts_name;
    static char           modules_alias_path[256];

    FILE*        file;
    char*        buf       = NULL;
    size_t       buf_size  = 0;
    const size_t read_size = 1024 * 1024;
    size_t       num_read;
    int          filename_len;
    int          i_arg;

    // Get kernel release string
    if (uname(&uts_name)) {
        perror("uname");
        return EXIT_FAILURE;
    }

    // Format path to modules.alias file
    filename_len = snprintf(modules_alias_path, sizeof(modules_alias_path),
                            "/lib/modules/%s/modules.alias", uts_name.release);
    if (filename_len > (int)sizeof(modules_alias_path) - 1) {
        fprintf(stderr, "%s: release version too long\n", uts_name.release);
        return EXIT_FAILURE;
    }

    // Open modules.alias file
    file = fopen(modules_alias_path, "r");
    if (!file) {
        perror(modules_alias_path);
        return EXIT_FAILURE;
    }

    // Load modules.alias file
    do {
        buf = realloc(buf, buf_size + read_size);
        if (!buf) {
            perror("realloc");
            return EXIT_FAILURE;
        }

        num_read = fread(buf + buf_size, 1, read_size, file);
        buf_size += num_read;
    } while (num_read == read_size);

    if (ferror(file)) {
        perror(modules_alias_path);
        return EXIT_FAILURE;
    }

    // Process each argument
    for (i_arg = 1; i_arg < argc; i_arg++) {
        const char* const mod_alias = argv[i_arg];
        char*             aliases   = buf;
        size_t            num_left  = buf_size;
        int               found     = 0;

        // Process each line in modules.alias file
        while (num_left) {
            char*        line     = aliases;
            const char*  eol      = (char*)memchr(line, '\n', num_left);
            char*        glob_end;
            size_t       line_len = eol ? (size_t)(eol - line + 1) : num_left;
            size_t       glob_len;
            size_t       mod_len;
            static char  alias[]  = "alias";

            aliases  += line_len;
            num_left -= line_len;

            // Skip leading spaces
            while (line_len && isspace(*line)) {
                ++line;
                --line_len;
            }

            // Check and skip "alias"
            if (line_len <= sizeof(alias) - 1)
                continue;
            if (memcmp(line, alias, sizeof(alias) - 1))
                continue;
            line     += sizeof(alias) - 1;
            line_len -= sizeof(alias) - 1;

            // Skip spaces
            while (line_len && isspace(*line)) {
                ++line;
                --line_len;
            }

            // Extract glob pattern
            glob_end = (char*)memchr(line, ' ', line_len);
            if (!glob_end)
                glob_end = (char*)memchr(line, 0, line_len);
            if (!glob_end)
                glob_end = (char*)memchr(line, '\t', line_len);
            if (!glob_end)
                continue;
            glob_len = glob_end - line;

            // Compare module alias from command line argument against the glob
            *glob_end = 0;
            if (fnmatch(line, mod_alias, 0))
                continue;

            // Skip glob pattern
            line     += glob_len + 1;
            line_len -= glob_len + 1;

            // Skip spaces
            while (line_len && isspace(*line)) {
                ++line;
                --line_len;
            }

            // Determine length of module name
            for (mod_len = 0; mod_len < line_len; mod_len++) {
                if (isspace(line[mod_len]))
                    break;
            }

            // Print module name
            printf("%.*s\n", (int)mod_len, line);
            found = 1;
            break;
        }

        // Print empty line if a match couldn't be found
        if (!found)
            printf("\n");
    }

    return EXIT_SUCCESS;
}
