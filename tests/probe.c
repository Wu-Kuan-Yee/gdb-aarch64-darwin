/* Test program for the gdb-aarch64-darwin smoke test.
   Copyright (C) 2026 Wu Kuan Yee

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 3 of the License, or
   (at your option) any later version.  */

#include <stdio.h>

static int counter;

static int
add (int a, int b)
{
  counter++;
  return a + b;
}

int
main (void)
{
  int sum = 0;
  int i;

  for (i = 0; i < 5; i++)
    sum = add (sum, i);

  printf ("sum=%d counter=%d\n", sum, counter);
  return 0;
}
