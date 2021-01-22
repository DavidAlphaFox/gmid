/*
 * Public domain.
 * Written by Matthew Dempsky.
 */

#include <string.h>

#include "../config.h"

void
explicit_bzero(void *buf, size_t len)
{
	memset(buf, 0, len);
}
