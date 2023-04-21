/*
 * Copyright (c) 2009-2023, NVIDIA CORPORATION.  All rights reserved.
 * See LICENSE file for details.
 */

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        printf("Usage: setdomainname <DOMAINNAME>\n");
        return 1;
    }

    if (setdomainname(argv[1], strlen(argv[1]))) {
        perror(argv[1]);
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}
