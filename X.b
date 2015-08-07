// a user process

import "io"
import "sys_lib"

let rr(x) be
{ let a = 10, b = 20, c = 30, d =40, e = 50;
  out("%d\n", x);
  if x > 0 then rr(x-1) }

let start() be
{ rr(5000);
  //exit(1);
}
