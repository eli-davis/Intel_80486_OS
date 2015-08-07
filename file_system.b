import "io"

// For now directory entries are limited to one block each (128 words = 512 bytes),
// which means directories are limited to 16 child files and directories. These child
// directories are also limited to 16 entries, etc.
// Each directory contains:
// + 512 bytes
// + up to 16 structs of 28 bytes, each describing a child file or directory
// + 6 bytes for the directorys name
// + 4 bytes for the location on disc of it's parent directory

// Files serve as a place holder as well, and include one header block with
// 28 words of descriptive information: name, permissions, time created, etc
// and 100 pointers to the file's contents.
// 100 pointers * 512 bytes per block = max file size 50KB

// + Directories require one disc read to open
// + Files take one disc read to open the header block
//   plus one disc read to access each of the up to 100 blocks of contents

// Goal was to have a basic file system (support for files and directories)
// to test the underlying operating system and catch any problems
// before optimizing. The features being tested are
// + virtual memory, page directory with page tables for six separate regions
//   of virtual address space (user and system code, heap, and stack)
// + page fault handler to grow heap and stack
// + ability to read in and execute user programs
// + exit() system call to restore system FP, SP, and PC
//   set CPU flags, recycle user process pages
// + interrupt based keyboard input system
// + allocating and recycling heap with newvec and freevec

// In progress
// + queue of user processes that take turns running

// Next up
// + B+ tree to accomodate large files with minimal disc reads

export
{
    on_start,
    on_shutdown,
    mkdir,
    cd,
    rmdir,
    fcreate,
    fopen,
    fwrite,
    fread,
    fclose,
    fdelete,
    fdebug
}

manifest
{
    disc_one        = 1,
    words_per_block = 128,
    bytes_per_block = 512,
    blocks_per_disc = 6000
}

let disc_check(disc_number) be
{
    let n = devctl(DC_DISC_CHECK, disc_number);
    if n <> blocks_per_disc then
    {
        out("disc check failed for disc %d", disc_number);
    }
    resultis n
}

let disc_read(block_number, number_of_blocks, address) be
{
    let r = devctl(DC_DISC_READ, disc_one, block_number, number_of_blocks, address);
    //out("read %d block(s)\n", r);
    if r <> number_of_blocks then
    {
        out("disc read failed for block %d", block_number);
    }
    resultis r
}

let disc_write(block_number, number_of_blocks, address) be
{
    let w = devctl(DC_DISC_WRITE, disc_one, block_number, number_of_blocks, address);
    //out("wrote %d block(s)\n", w);
    if w <> number_of_blocks then
    {
        out("disc write failed for block %d", block_number);
    }
    resultis w
}

// roughly 2% of disc is used for a queue of words
// that keep track of which blocks are in use
// todo:
// + queue of bits instead of queue of words (< 0.1% of disc)
// + instead of exclusively writing the queue to disc at the end of the file
//   keep a portion of the queue in memory and periodically write changes to disc
// future work:
// + keep track of what changes haven't been written to disc yet, and then have a
//   recovery mode in on_start() to write these changes the next time the system is run

manifest
{
    queue_start = 112;
    blocks_in_queue = 5888
}

static
{
    super_block,
    user_blocks_reserved,
    user_blocks_available,
    queue_of_blocks,
    current_disc = 1
}

let new_block() be
{
    let block = -1;
    static { queue_pos = queue_start }
    if user_blocks_available > 0 then
    {
        until (queue_of_blocks ! queue_pos bitand 1) = 0 do
        {
            queue_pos +:= 1;
            if queue_pos = blocks_per_disc then
            {
                queue_pos := queue_start
            }
        }
        queue_of_blocks ! queue_pos := 1;
        block := queue_pos;
        user_blocks_reserved  +:= 1;
        user_blocks_available -:= 1;
    }
    if block = -1 then
    {
        out("disc %d full\n", current_disc);
        //todo: call an interrupt
        finish;
    }
    resultis block
}

let erase_block(block_number) be
{
    let current_block = vec(words_per_block);
    disc_read(block_number, 1, current_block);
    for ii = 0 to 127 do
    {
        current_block ! ii := 0
    }
    disc_write(block_number, 1, current_block);
}

let free_block(block_number) be
{
    queue_of_blocks ! block_number := 0;
    user_blocks_available +:= 1;
    user_blocks_reserved  -:= 1
}


let strcmp(a, b) be
{
    if strlen(a) <> strlen(b) then resultis false;
    for i = 0 to strlen(a) do
    {
        if byte i of a <> byte i of b then
        {
            resultis false
        }
    }
    resultis true
}

let strcpy(a, b) be
{
    let length = strlen(b);
    byte length of a := 0;
    for ii = 0 to length-1 do
    {
        byte ii of a := byte ii of b
    }
    //out("string b is %s\n", b);
    //out("string a is %s\n", a);
}


// directory entry is 7 words
// -  bytes  0 - 22: name + '\0'
// -  byte       23: DIR = 0, FILE = 1
// -  bytes 24 - 27: header block number

// directories are 128 words
// -  structs at locations 0, 7, ... 112 are entries
// -  words 119-125 contain the name and location of the working directory
// -  word 126 is location of parent directory

manifest
{
    words_per_entry = 7,
    max_name_length = 21,

    // indexes
    last_entry = 112,
    self       = 119,
    parent     = 126
}

//the root directory is located at block 1
static
{
    active_directory = 1
}

let change_directory(name) be
{
    let current_directory = vec(words_per_block);
    let entry = 0;

    test strcmp(".", name) then
    {
        return
    }
    else test strcmp("..", name) then
    {
        disc_read(active_directory, 1, current_directory);
        active_directory := current_directory ! parent;
    }
    else test strcmp("root", name) then
    {
        active_directory := 1;
    }
    else
    {
        disc_read(active_directory, 1, current_directory);
        for ii = 0 to last_entry by words_per_entry do
        {
           entry := current_directory + ii;
           if entry ! 0 = 0 then
           {
               break;
           }
           if byte 23 of entry = 1 then
           {
               loop
           }
           //out("'%s' ", entry);
           //out(" (header @ %d)\n", entry ! 6);
           if strcmp(entry, name) then
           {
               active_directory := entry ! 6;
               return;
           }
        }
        out("\nDirectory %s not found\n", name)
    }
}

let print_active_directory() be
{
    let current_directory = vec(words_per_block);
    disc_read(active_directory, 1, current_directory);
    out("\ncurrent directory is '%s'\n", current_directory + self);
    out("  block number: %d\n", active_directory);
    out("  parent block number: %d\n\n", current_directory ! parent)
}

let list_active_directory() be
{
    let current_directory = vec(words_per_block), entry = 0;
    disc_read(active_directory, 1, current_directory);

    out("\n\ncurrent directory is '%s':\n", current_directory + self);
    out("  block number: %d\n", active_directory);
    out("  parent block number: %d\n", current_directory ! parent);
    for ii = 0 to last_entry by words_per_entry do
    {
        entry := current_directory + ii;
        if entry ! 0 = 0 then
        {
            break;
        }
        out("%4d: ", ii/words_per_entry);
        test byte 23 of entry = 0 then
        {
            out("DIR ");
        }
        else
        {
            out("FILE ");
        }
        out("'%s'", entry);
        out(" is located at block number %d\n", entry ! 6);
    }
}

let create_directory(name) be
{
    let name_length = strlen(name);
    let current_directory = vec(words_per_block);
    let pos = 0, entry = 0;
    let new_directory = 0;

    if name_length > max_name_length then
    {
        out("create directory %s:\n, name");
        out("    directory not created- name is too long\n");
        out("    max name length is %d characters\n", max_name_length);
        return
    }
    disc_read(active_directory, 1, current_directory);
    while true do
    {
        if pos = last_entry + words_per_entry then
        {
           out("create directory %s:\n", name);
           out("    directory not created- active directory is full\n");
           return
        }
        if strcmp(name, current_directory + pos) \/ strcmp(name, "root") then
        {
           out("create directory %s:\n", name);
           out("    directory not created- name conflict\n", name);
           return
        }
        if current_directory ! pos = 0 then
        {
            entry := current_directory + pos;
            strcpy(entry, name);
            byte 23 of entry := 0;
            new_directory := new_block();
            entry ! 6 := new_directory;
            break;
        }

        pos +:= words_per_entry;
    }

    disc_write(active_directory, 1, current_directory);

    // save the new directory's name and parent directory location
    if new_directory <> 0 then
    {
        disc_read(new_directory, 1, current_directory);
        strcpy(current_directory + self, name);
        current_directory ! parent := active_directory;
        disc_write(new_directory, 1, current_directory);
    }

}

// frees and recycles a directory, that directory's children,
// children's children, etc recursively
let remove_directory(parent_directory, name) be
{
    let current_directory = vec(words_per_block);
    let child_directory, entry;
    let top_level = true;
    let is_a_file = 0;

    if strcmp(name, "remove-all") then
    {
        out("remove all\n");
        top_level := false;
    }
    test strcmp("root", name) then
    {
        out("not permitted to delete root directory\n");
        return;
    }
    else
    {
        disc_read(parent_directory, 1, current_directory);
        for ii = 0 to last_entry by words_per_entry do
        {
           entry := current_directory + ii;
           out("%d/%s\n", entry ! 0 , entry);
           if entry ! 0 = 0 then
           {
               if top_level then
               {
                   out("remove directory %s failed- directory not found\n", name);
               }
               return
           }
           // non-recursive call
           test top_level then
           {
               is_a_file := byte 23 of entry;
               if is_a_file = 0 /\ strcmp(entry, name) then
               {
                   child_directory := entry ! 6;
                   out("%d\n", child_directory);
                   remove_directory(child_directory, "remove-all");
                   free_block(child_directory);
                   //shift remaining directory entries to fill in the gap
                   for jj = (ii * 4) to ((last_entry - words_per_entry) * 4) do
                   {
                       byte jj of current_directory := byte (jj + 28) of current_directory;
                   }
                   //save active directory
                   disc_write(parent_directory, 1, current_directory);
                   return;
               }
           }
           // recursive call
           else
           {
               child_directory := entry ! 6;
               out("%d\n", child_directory);
               remove_directory(child_directory, "remove-all");
               free_block(child_directory)
           }

        }
        if top_level then
        {
            out("remove directory %s failed- directory not found\n", name);
        }
    }
}


let create_file(name) be
{
    let name_length = strlen(name);
    let current_directory = vec(words_per_block);
    let current_file = vec(words_per_block);
    let pos = 0, entry = 0;
    let new_file_header_block = 0, new_file_data_block = 0;
    let date_and_time = vec(7);

    if name_length > max_name_length then
    {
        out("create file %s:\n, name");
        out("    file not created- name is too long\n");
        out("    max name length is %d characters\n", max_name_length);
        return
    }
    disc_read(active_directory, 1, current_directory);
    while true do
    {
        if pos = last_entry + words_per_entry then
        {
           out("create file %s:\n", name);
           out("    file not created- active directory is full\n");
           return
        }
        if strcmp(name, current_directory + pos) \/ strcmp(name, "root") then
        {
           out("create file %s:\n", name);
           out("    file not created- name conflict\n", name);
           return
        }
        if current_directory ! pos = 0 then
        {
            entry := current_directory + pos;
            strcpy(entry, name);
            byte 23 of entry := 1;
            new_file_header_block := new_block();
            new_file_data_block := new_block();
            entry ! 6 := new_file_header_block;
            break;
        }

        pos +:= words_per_entry;
    }

    disc_write(active_directory, 1, current_directory);

    // create the file's header block and one initial data block

    // header block contains a struct of 28 words and 100 pointers
    // to data blocks. this "1-level" file system is a placeholder
    // for a B+ tree thats in progress. 28 words is excessive
    // as a header struct size - its so that 100 words are left over
    // for pointers. 100 is a nicer number to work with then like 115
    // and I can always optimize the header size after I've made
    // additional progress.
    // That being said, the header struct in the header block contains
    // +   0-5: name
    // +     6: header block location
    // +     7: first data block location
    // +     8: num_data_blocks
    // +     9: num_words
    // +    10: num_bytes
    // +    11: permission (1 = READ, 2 = WRITE, 3 = EXECUTE, 4 = all permitted)
    // + 12-17: time created
    // + 18-23: time of last access
    // +    24: words written to file
    // +    25: is file open (0 or 1)
    // +    26: position in file (bytes)
    // +    27: current data block

    if new_file_header_block <> 0 then
    {
        disc_read(new_file_header_block, 1, current_file);
        strcpy(current_file, name);
        current_file !  6 := new_file_header_block;
        current_file !  7 := new_file_data_block;
        current_file !  8 := 1;
        current_file !  9 := words_per_block;
        current_file ! 10 := bytes_per_block;
        current_file ! 11 := 4;
        datetime(seconds(), date_and_time);
        current_file ! 12 := date_and_time ! 1;
        current_file ! 13 := date_and_time ! 2;
        current_file ! 14 := date_and_time ! 0;
        current_file ! 15 := date_and_time ! 4;
        current_file ! 16 := date_and_time ! 5;
        current_file ! 17 := date_and_time ! 6;
        current_file ! 18 := date_and_time ! 1;
        current_file ! 19 := date_and_time ! 2;
        current_file ! 20 := date_and_time ! 0;
        current_file ! 21 := date_and_time ! 4;
        current_file ! 22 := date_and_time ! 5;
        current_file ! 23 := date_and_time ! 6;
        current_file ! 24 := 0;
        current_file ! 25 := 0;
        current_file ! 26 := 0;
        current_file ! 27 := new_file_data_block;
        current_file ! 28 := new_file_data_block;
        disc_write(new_file_header_block, 1, current_file);
    }

}

//header indexes
manifest
{
    header_block     = 6,
    first_data_block = 7,
    num_data_blocks  = 8,
    num_words        = 9,
    num_bytes        = 10,
    permission       = 11,
    words_written    = 24,
    is_open          = 25,
    position         = 26,
    current_block    = 27,
    first_data_ptr   = 28

}

let print_time_created(file_header_block) be
{
    let f = vec(words_per_block);
    disc_read(file_header_block, 1, f);
    out("time created:\n");
    out("%d/%d/%d ",  f!12, f!13, f!14);
    out("%02d:%02d.%02d\n", f!15, f!16, f!17);
}

let print_time_last_accessed(file_header_block) be
{
    let f = vec(words_per_block);
    disc_read(file_header_block, 1, f);
    out("time last accessed:\n");
    out("%d/%d/%d ",  f!18, f!19, f!20);
    out("%02d:%02d.%02d\n", f!21, f!22, f!23)
}

let print_file_header(name) be
{
    let current_directory = vec(words_per_block), entry;
    let f = vec(words_per_block);
    let file_header_block = 0;

    disc_read(active_directory, 1, current_directory);
    for ii = 0 to last_entry by words_per_entry do
    {
        entry := current_directory + ii;
        if entry ! 0 = 0 then
        {
            break;
        }
        if byte 23 of entry = 0 then
        {
            loop
        }
        if strcmp(entry, name) then
        {
            file_header_block := entry ! 6;
        }
    }
    test file_header_block <> 0 then
    {
        disc_read(file_header_block, 1, f);
        out("file %s\n", f);
        out("  header block:  %d\n", f ! header_block);
        out("  first  block:  %d\n", f ! first_data_block);
        out("  num blocks:    %d\n", f ! num_data_blocks);
        out("  num words:     %d\n", f ! num_words);
        out("  num bytes:     %d\n", f ! num_bytes);
        out("  permission:    %d\n", f ! permission);
        out("  words written: %d\n", f ! words_written);
        out("  is open:       %d\n", f ! is_open);
        out("  byte pos:      %d\n", f ! position);
        out("  byte pos:      %d\n", f ! current_block);
        out("  first ptr:     %d\n", f ! first_data_ptr);
        print_time_created(file_header_block);
        print_time_last_accessed(file_header_block)
    }
    else
    {
        out("\nFile %s not found\n", name);
    }
}

let delete_file(name) be
{
    let current_directory = vec(words_per_block);
    let f_header_block, entry, num_blocks;
    let is_a_file = 0;
    let f = vec(words_per_block);

    if strcmp("root", name) then
    {
        return;
    }
    disc_read(active_directory, 1, current_directory);
    for ii = 0 to last_entry by words_per_entry do
    {
        entry := current_directory + ii;
        out("%d/%s\n", entry ! 0 , entry);
        if entry ! 0 = 0 then
        {
            out("remove file %s failed- file not found\n", name);
            return
        }
        is_a_file := byte 23 of entry;
        if is_a_file = 1 /\ strcmp(entry, name) then
        {
            f_header_block := entry ! 6;
            out("%d", f_header_block);
            disc_read(f_header_block, 1, f);
            num_blocks := f ! num_data_blocks;
            out("  %d\n", num_blocks);
            for ii = first_data_ptr to (first_data_ptr + num_blocks - 1) do
            {
                free_block(f ! ii);
            }
            free_block(f_header_block);
            //shift remaining directory entries to fill in the gap
            for jj = (ii * 4) to ((last_entry - words_per_entry) * 4) do
            {
                byte jj of current_directory := byte (jj + 28) of current_directory;
            }
            //save active directory
            disc_write(active_directory, 1, current_directory);
            return;
        }
    }
    out("remove file %s failed- file not found\n", name);
}

manifest
{
  read = 1,
  write = 2,
  execute = 3,
  all_permitted = 4
}

static
{
    f_pos        = 0,
    f_buffer     = 0,
    f_buffer_pos = 0,
    f_permission = 0,
    f_current_block = -1,
    f_header        = -1,
    f_current_ptr   = -1
}

let print_active_file() be
{
    out("buffer is located at 0x%x\n", f_buffer);
    out("buffer pos: %d\n", f_buffer_pos);
    out("permission: %d\n", f_permission);
    out("pos in bytes %d\n", f_pos);
    out("current block: %d\n", f_current_block);
    out("header block: %d\n", f_header);
    out("current ptr: %d\n", f_current_ptr)
}

// + search active directory for file
// + check permissions
// + create a buffer for reading and writing
// + return file's header block or -1
let fopen(name, read_or_write) be
{
    let f_header_block = -1;
    let f = vec(words_per_block);

    let current_directory = vec(words_per_block);
    let entry, num_blocks;
    let is_a_file = 0;

    disc_read(active_directory, 1, current_directory);

    for ii = 0 to last_entry by words_per_entry do
    {
        entry := current_directory + ii;
        //out("%d/%s\n", entry ! 0 , entry);
        if entry ! 0 = 0 then
        {
            out("open file %s failed- file not found\n", name);
            resultis -1;
        }
        is_a_file := byte 23 of entry;
        if is_a_file = 1 /\ strcmp(entry, name) then
        {
            f_header_block := entry ! 6;
            //out("%d", f_header_block);
            disc_read(f_header_block, 1, f);
            f_header := f_header_block;
            num_blocks := f ! num_data_blocks;
            //out("  %d\n", num_blocks);
            f_permission := f ! permission;
            //out("per  %d\n", f_permission);
            if f_permission <> all_permitted /\ f_permission <> read_or_write then
            {
                out("open file %s failed- incorrect permission\n", name);
                f_permission := 0;
                resultis -1
            }
            f_pos := f ! position;
            //out("  %d\n", f_pos);
            f_buffer := newvec(words_per_block);
            f_buffer_pos := 0;
            f_current_ptr := first_data_ptr;
            f ! is_open := 1;
            disc_read(f_header_block, 1, f);
            resultis f_header_block;
        }
    }
    out("open file %s failed- file not found\n", name);
    resultis -1
}

// fwrite and fread are really simple for now and need further testing
// as mentioned goal for now is to have all the basics
// for testing virtual memory, page allocation, and newvec / freevec

// write from vector to file
// return bytes written or -1
let fwrite(f_header_block, v, sizeof_v) be
{
    let f = vec(words_per_block);
    let position_in_block = f_pos rem bytes_per_block;
    let bytes_written = 0;

    if f_header <> f_header_block then
    {
        out("write to file failed- file is not open\n");
        resultis -1
    }
    if f_permission <> write /\ f_permission <> all_permitted then
    {
        out("write to file failed- incorrect permission\n");
        resultis -1
    }
    if position_in_block <> f_buffer_pos then
    {
        //debugging
        out("fwrite failed: buffer position is not aligned with block\n");
        resultis -1
    }

    disc_read(f_header_block, 1, f);
    for ii = 0 to sizeof_v-1 do
    {
        if f_buffer_pos = bytes_per_block then
        {
            disc_write(f_current_block, 1, f_buffer);
            for jj = 0 to 127 do
            {
                f_buffer ! jj := 0;
            }
            f_current_block := new_block();
            f_current_ptr +:= 1;
            if f_current_ptr = words_per_block then
            {
                out("file size limit met (50kb, for now) met\n");
                out("wrote %d of %d bytes\n", bytes_written, sizeof_v);
                resultis bytes_written
            }
            f ! f_current_ptr := f_current_block;
            f_buffer_pos := 0;
        }
        byte f_buffer_pos of f_buffer := byte ii of v;
        f_buffer_pos +:= 1;
        bytes_written +:= 1;
        f_pos +:= 1;
    }
    disc_write(f_current_block, 1, f_buffer);
    for jj = 0 to 127 do
    {
        f_buffer ! jj := 0;
    }
    disc_write(f_header_block, 1, f);
    resultis bytes_written
}

// read file into vector v
// return bytes read or -1
let fread(f_header_block, v, num_blocks) be
{
    let f = vec(words_per_block);
    let read_buffer = vec(words_per_block);
    let bytes_read = 0;

    if f_header <> f_header_block then
    {
        out("fread failed- file is not open\n");
        resultis -1
    }
    if f_permission <> write /\ f_permission <> all_permitted then
    {
        out("fread failed- incorrect permission\n");
        resultis -1
    }

    disc_read(f_header_block, num_blocks, v);
    resultis bytes_per_block * num_blocks;

}

let fclose(f_header_block) be
{
    if f_header <> f_header_block then
    {
        out("close file failed- file is not open\n");
        resultis -1
    }
    f_buffer := 0;
    f_buffer_pos := 0;
    f_permission := 0;
    f_pos := 0;
    f_current_block := -1;
    f_header_block := -1;
    f_current_ptr := -1
}


let on_start(first_time_booting_up) be
{
    let root_directory  = vec(words_per_block);
    super_block     := newvec(words_per_block);
    queue_of_blocks := newvec(blocks_per_disc);

    if first_time_booting_up = true then
    {
        super_block ! 0 := 1;
        super_block ! 1 := 0;     //user_blocks_reserved
        super_block ! 2 := 5888;  //user_blocks_available

        strcpy(root_directory + self, "root");
        root_directory ! parent := 1;

        for ii = queue_start to blocks_per_disc-1 do
        {
            erase_block(ii);
            queue_of_blocks ! ii := 0
        }

        disc_write(0,   1, super_block);
        disc_write(1,   1, root_directory);
        disc_write(10, 46, queue_of_blocks);
    }

    disc_check(disc_one);
    disc_read(0,  1,  super_block);
    disc_read(10, 46, queue_of_blocks);

    user_blocks_reserved  := super_block ! 1;
    user_blocks_available := super_block ! 2;
}

let on_shutdown() be
{
    out("\n\nON_EXIT\n");
    for ii = 0 to words_per_block-1 do
    {
        if super_block ! ii <> 0 then
        {
            out("superblock %d: %d\n", ii, super_block ! ii);
        }
    }

    out("\nQueue:\n");
    for ii = 0 to blocks_in_queue-1 do
    {
        if queue_of_blocks ! ii <> 0 then
        {
            out("%d: %d \n", ii, queue_of_blocks ! ii);
        }
    }

    super_block ! 1 := user_blocks_reserved;
    super_block ! 2 := user_blocks_available;
    disc_write(0,   1, super_block);
    disc_write(10, 46, queue_of_blocks);

}

let mkdir(name) = create_directory(name);
let rmdir(name) = remove_directory(active_directory, name)
let cd(name)    = change_directory(name);

let fcreate(name) = create_file(name);
let fdelete(name) = delete_file(name);
let fdebug(name) = print_file_header(name);
