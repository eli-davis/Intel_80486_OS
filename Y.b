// a user process
import "io"
import "sys_lib"

let idle(n) be
 for i=1 to n do
 assembly { pause }

let start() be
{
    let line = vec(line_size);
    let t;
    let argc = 0;
    let argv = vec(max_argc);

  out("start\n");
  init_newvec();

  t := newvec(4000);
  freevec(t);

  while true do
  {
      out("\n~~~ > ");
      get_line(line);
      out("\n'%s'\n", line);
      argc := get_argv(line, argv);
      out("\n\n");
      for ii = 1 to argc do
      {
          out("%d: '%s'\n", ii, argv ! ii);
      }
      if strcmp("q", argv ! 1) \/ strcmp("quit", argv ! 1) then
      {
          break
      }
      free_argv(argc, argv);

  }

  t := get_time();
  out ("%d\n", t);
  out("done\n");

}
