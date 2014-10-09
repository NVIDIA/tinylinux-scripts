#include <unistd.h>
#include <string.h>
#include <stdio.h>

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        printf("Usage: setdomainname <DOMAINNAME>\n");
        return 1;
    }
    setdomainname(argv[1], strlen(argv[1]));
    return 0;
}
