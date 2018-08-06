 
written in a slightly modified version of BCPL  
(http://rabbit.eng.miami.edu/class/een521/bcpl-2.pdf)  

for an intel 80486 emulator  
+ http://rabbit.eng.miami.edu/class/een521/hardware-1.pdf  
+ http://rabbit.eng.miami.edu/class/een521/hardware-2a.pdf  
+ http://rabbit.eng.miami.edu/class/een521/intel486vm.pdf  

emulator written by dr. stephen murrell  
(source code: http://rabbit.eng.miami.edu/class/een521/een521.zip)  


inside this repot:
+ **start.b:** virtual memory (for the 80846. 4GB memory = 512 pages * 2048 words per page. word = 32 bits)  
  page directory with page tables for six separate regions  
  of virtual address space (user and system code, heap, and stack)  
+ **os.b:** page fault handler to grow heap and stack  
  ability to read in and execute user programs  
  exit() system call to restore system FP, SP, and PC, set CPU flags and recycle user process pages  
  interrupt based keyboard input system  
  command line shell  
  (in process) queue of runnable processes  
+ **newvec.b:** allocating and recycling heap with newvec and freevec  
+ **file_system.b:** basic file system (mkdir, cd, rmdir, fcreate, fdelete, fopen, fclose, fwrite, fread)  
+ **sys_lib.b:** basic system call api for user processes  
+ **user processes X.b, Y.b:** for testing

For now directory entries are limited to one block each (128 words = 512 bytes),  
which means directories are limited to 16 child files and directories. These child  
directories are also limited to 16 entries, etc.  
Each directory contains:  
+ 512 bytes  
+ up to 16 structs of 28 bytes, each describing a child file or directory  
+ 6 bytes for the directorys name  
+ 4 bytes for the location on disc of it's parent directory  

Files serve as a place holder as well, and include one header block with  
28 words of descriptive information: name, permissions, time created, etc  
and 100 pointers to the file's contents.  
100 pointers * 512 bytes per block = max file size 50KB  

+ Directories require one disc read to open  
+ Files take one disc read to open the header block  
  plus one disc read to access each of the up to 100 blocks of contents  

Goal was to have a basic file system (support for files and directories)  
to test the underlying operating system and catch any problems  
before optimizing. The features being tested are  
+ virtual memory, page directory with page tables for six separate regions  
  of virtual address space (user and system code, heap, and stack)  
+ page fault handler to grow heap and stack  
+ ability to read in and execute user programs  
+ exit() system call to restore system FP, SP, and PC  
   set CPU flags, recycle user process pages  
+ interrupt based keyboard input system  
+ + allocating and recycling heap with newvec and freevec  
  
  
  
In progress  
+ queue of user processes that take turns running  
+ testing fread and fwrite

Next up  
+ B+ tree to accomodate large files with minimal disc reads  



