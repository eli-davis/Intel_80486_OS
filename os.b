import "io"
import "new_vec"
import "file_system"

// System stuff

// pt_special_va ! 0  := pt_special bitor 1;
// pt_special_va ! 1  := pgdir bitor 1;
// pt_special_va ! 2  := system_heap_index
// pt_special_va ! 3  := call_gates bitor 1;
// pt_special_va ! 4  := interrupt_vec bitor 1;
// pt_special_va ! 5  := system_FP
// pt_special_va ! 6  := system_SP
// pt_special_va ! 7  := system_PC

// pt_special_va ! 10 := system_pgdir
// pt_special_va ! 11 := user_pgdir

//debugging
//out("system FP       = 0x%x\n", pt_special_va ! 5);
//out("system SP       = 0x%x\n", pt_special_va ! 6);
//out("system PC       = 0x%x\n", pt_special_va ! 7);
//out("system pgdir +f = 0x%x\n", pt_special_va ! 1);
//out("system pgdir    = 0x%x\n", pt_special_va ! 10);
//out("user   pgdir    = 0x%x\n", pt_special_va ! 11);




// Process Control Block

// infopage_va ! 0 := infopage bitor 1;
// infopage_va ! 1 := user_heap_index
// infopage_va ! 2 := user_code_index
// infopage_va ! 3 := user_stack_index
// infopage_va ! 4 := active_process_id  (0 = SYS)


//todo: add num_active_processes
manifest
{
    freelist_va       = 0x04000000,
    infopage_va       = 0x08000000,
    pt_system_heap_va = 0x0C000000,
    pt_user_heap_va   = 0x10000000,
    pt_user_code_va   = 0x40000000;
    pt_user_stack_va  = 0x7FC00000,

    pt_special_va    = 0xC0000000,
    pgdir_va         = 0xC0000800, // !1
    call_gates_va    = 0xC0001800, // !3
    intvec_va        = 0xC0002000, // !4
    user_pgdir_va    = 0xC0005800  // !11
}

// Page Allocation

static { num_pages = 0 }

// called once when starting up
//  + count the number of pages in the freelist
//  + save the result
let set_num_pages() be
{
    let ii = 1;
    while freelist_va ! ii <> 0 do
    {
        //out("VA: 0x%x\n", freelist_va + (ii * 0x800));
        ii +:= 1
    }
    num_pages := ii-1
}

// planned optimization: change loop to a stack
// currently
// + best case, unoccupied page found immendiately
// + worst case, loop has to check every page when memory is close to full (~500 pages for 4GB)
// third bit set (0100) signals occupied page, hence the check that (PAGE_X bitand 4 = 0)
let get_page() be
{
    static { next_page = 0 }
    for ii = 1 to num_pages do
    {
        next_page +:= 1;
        if next_page > num_pages then
        {
            next_page := 1;
        }
        // if page is unoccupied then return that page
        if ((freelist_va ! next_page) bitand 4) = 0 then
        {
            freelist_va ! next_page := (freelist_va ! next_page) bitor 4;
            resultis freelist_va ! next_page
        }
    }
    //todo: call an interrupt handler
    out("freelist is empty\n");
    out("OUT OF MEMORY\n");
    finish
}

let free_page(physical_addr) be
{
    let page_num = physical_addr >> 11, physical_page;
    for ii = 1 to num_pages do
    {
        if page_num = ((freelist_va ! ii) >> 11) then
        {
            //double check that this page is occupied
            if ((freelist_va ! ii) bitand 4) = 0 then
            {
                break;
            }
            //mark page as unoccupied
            freelist_va ! ii -:= 4;
            //erase contents
            physical_page := physical_addr bitand 0xFFFFF800;
            assembly
            { clrpp [<physical_page>] }
            return
        }
    }
    out("Free Page() error: page 0x%x not found\n", physical_addr);
    finish
}

manifest
{
    tape_one        = 1,
    words_per_block = 128,
    bytes_per_block = 512

}

let create_process(exe_name) be
{
    //page table indexes
    let user_heap_index  = 1;
    let user_code_index  = 1;
    let user_stack_index = 2047;

    let user_heap_page   = get_page();
    let user_code_page   = get_page();
    let user_stack_page  = get_page();

    //save system page directory, create a user page directory
    let system_pgdir, user_pgdir = get_page();
    let process_id = 0;

    //save system state
    let save_system_FP;
    let save_system_SP;
    let save_system_PC;

    //variables for reading in file
    let r = bytes_per_block;
    let bytes_read = 0;
    let available_blocks = 16;
    let user_code_address = pt_user_code_va + 0x800;

    // user code, heap, and stack get one page each to start
    pt_user_heap_va  ! user_heap_index  := user_heap_page;
    pt_user_code_va  ! user_code_index  := user_code_page;
    pt_user_stack_va ! user_stack_index := user_stack_page;


    // device control: set tape to read
    devctl(DC_TAPE_LOAD, tape_one, exe_name, 'R');

    // device control: check tape
    // if executable doesn't exist
    // + let the user know
    // + return to command line to execute the next command
    if devctl(DC_TAPE_CHECK, tape_one) = 0 then
    {
        out("file %s not found\n", exe_name);
        return
    }

    // read in user executable code
    // allocate more pages as needed
    while r = bytes_per_block do
    {
        r := devctl(DC_TAPE_READ, 1, user_code_address);
        if r < 0 then
        {
            out("error %d while reading tape '%s'\n", r, exe_name);
            finish
        }
        bytes_read +:= r;
        available_blocks -:= 1;
        user_code_address +:= words_per_block;
        if available_blocks = 0 then
        {
            user_code_page := get_page();
            user_code_index +:= 1;
            pt_user_code_va ! user_code_index := user_code_page;
            available_blocks := 16
        }
    }
    out("\nLoaded %d pages (%d bytes) of '%s'\n", user_code_index, bytes_read, exe_name);

    // Process Control Block
    infopage_va ! 1 := user_heap_index;
    infopage_va ! 2 := user_code_index;
    infopage_va ! 3 := user_stack_index;

    // todo: get_process_id()
    infopage_va ! 4 := 1;

    // todo: get_user_pgdir_index()
    // copy page directory
    pt_special_va ! 11 := user_pgdir;
    for ii = 0 to 0x7FF do
    {
        if pgdir_va ! ii <> 0 then
        {
            user_pgdir_va ! ii := pgdir_va ! ii;
            out("system pgdir ! 0x%x: 0x%x\n", ii, pgdir_va ! ii);
            out("user   pgdir ! 0x%x: 0x%x\n", ii, user_pgdir_va ! ii);
            out("\n")
        }
    }

    // for user and system page directories
    // + clear flag bits
    // + save
    system_pgdir := (pt_special_va ! 1) bitand 0xFFFFF800;
    user_pgdir   := user_pgdir bitand 0xFFFFF800;
    pt_special_va ! 10 := system_pgdir;
    pt_special_va ! 11 := user_pgdir;

    save_system_FP := @(pt_special_va ! 5);
    save_system_SP := @(pt_special_va ! 6);
    save_system_PC := @(pt_special_va ! 7);

    assembly
    {
        load      r1, [<save_system_FP>]
        load      r2, fp
        store     r2, [r1]
        load      r1, [<save_system_SP>]
        load      r2, sp
        store     r2, [r1]
        load      r1, [<save_system_PC>]
        load      r2, pc
        add       r2, 13
        store     r2, [r1]

        load      r1, [<user_pgdir>]
        setsr     r1, $pdbr
        getsr     r1, $flags
        cbit      r1, $sys
        setsr     r1, $flags
        load      sp, 0x0000
        loadh     sp, 0x8000
        load      fp, sp
        load      r2, 0x0800
        loadh     r2, 0x4000
        jump      r2
    }

    // exit() jumps here based on saved system PC + 13
    out("File %s finished\n", exe_name);

    process_id := infopage_va ! 4;
    recycle_process(exe_name, process_id);
    free_page(user_pgdir);

    //set process id to SYSTEM
    infopage_va ! 4 := 0;
}

// clear all pages of user code, heap, and stack
// and mark these pages for reuse
and recycle_process(file_name, process_id) be
{
    let user_heap_index  = infopage_va ! 1;
    let user_code_index  = infopage_va ! 2;
    let user_stack_index = infopage_va ! 3;

    out("user heap  index  = 0x%x\n", user_heap_index);
    out("user code  index  = 0x%x\n", user_code_index);
    out("user stack index = 0x%x\n", user_stack_index);

    for ii = 1 to user_code_index do
    {
        free_page(pt_user_code_va ! ii);
    }
    for ii = 1 to user_heap_index do
    {
        free_page(pt_user_heap_va ! ii);
    }
    // debugging
    //for ii = 2047 to user_stack_index by -1 do
    //{
    //    out("XX 0x%x XX\n", pt_user_stack_va ! ii);
    //    free_page(pt_user_stack_va ! ii);
    //}
    out("\nfile %s recycled\n", file_name)
}

// restore system PC, FP, SP and pgdir
// when Program Counter is restored (to the last line of create_process)
// + recycle_process() will be called
// + shell will prompt user for next command
let exit(err_code) be
{
    let system_pgdir = pt_special_va ! 10;
    let system_FP    = pt_special_va ! 5;
    let system_SP    = pt_special_va ! 6;
    let system_PC    = pt_special_va ! 7;

    out("exit(%d)\n", err_code);

    out("X1/ pgdir 0x%x\n", pt_special_va ! 1);
    out("X1/ FP    0x%x\n", pt_special_va ! 5);
    out("X1/ SP    0x%x\n", pt_special_va ! 6);
    out("X1/ PC    0x%x\n", pt_special_va ! 7);

    out("\n\n");

    out("X2/ pgdir 0x%x\n", system_pgdir);
    out("X2/ FP    0x%x\n", system_FP);
    out("X2/ SP    0x%x\n", system_SP);
    out("X2/ PC    0x%x\n", system_PC);


    // tell CPU we're in system mode
    // and ready for interrupts ($ip is set when halt executed, so clear $ip)
    assembly
    {
        getsr     r5, $flags
        sbit      r5, $sys
        cbit      r5, $ip
        setsr     r5, $flags
    }

    // restore system FP, SP, PC
    // setting PC causes CPU to jump to recycle_process()
    assembly
    {
        load      r1, [<system_FP>]
        load      r2, [<system_SP>]
        load      r3, [<system_PC>]
        load      r4, [<system_pgdir>]
        setsr     r4, $pdbr
        load      fp, r1
        load      sp, r2
        load      pc, r3
    }
}

let exit_syscall(code, rn, arg_vec) be
{
    let err_code = 0;
    let num_arguments = arg_vec ! 0;
    out("num args = %d\n", num_arguments);
    if num_arguments = 1 then
    {
        err_code := arg_vec ! 1;
    }
    exit(err_code)
}

// user process halt interrupt handler
// interrupt handler tells cpu to ignore interrupts
// but exit will fix this by clearing cpu flag $ip
let ihandle_exit(intcode, address, info, pc) = exit(0)



// Keyboard I/O

manifest
{
    buffer_size     = 100, //words
    max_buffer_pos  = 399, //characters
    max_line_length = 399, //characters

    string_size = 25, //words
    max_strlen  = 99  //characters
}

static
{
    buffer,
    buffer_pos,
    recent_line,
    line_num
}

let set_keyboard_buffer(kb_buffer, line_buffer) be
{
    buffer_pos  := 0;
    line_num    := 0;
    buffer      := kb_buffer;
    recent_line := line_buffer;
}

let ihandle_keyboard(intcode, address, info, pc) be
{
    let char;
    assembly
    {
        inch     r1
        store    r1, [<char>]
    }

    //backspace
    test (char = 8 \/ char = 127) then
    {
        if buffer_pos > 0 then
        {
            out("\b \b");
            buffer_pos -:= 1
        }
    }
    else test char = '\n' then
    {
        out("\n");
        byte buffer_pos of buffer := char;
        for pos = 0 to buffer_pos do
        {
            byte pos of recent_line := byte pos of buffer;
        }
        line_num +:= 1;
        buffer_pos := 0
    }
    //ctrl-u to delete line
    else test char = 21 then
    {
        until buffer_pos = 0 do
        {
            out("\b \b");
            buffer_pos -:= 1
        }
    }
    else
    {
        if buffer_pos <= max_buffer_pos then
        {
            outch(char);
            byte buffer_pos of buffer := char;
            buffer_pos +:= 1
        }
    }

    ireturn;
}


let get_line(line) be
{
    let current_line = line_num;
    until current_line <> line_num do
    {
        assembly { pause }
    }
    for ii = 0 to max_line_length do
    {
        byte ii of line := byte ii of recent_line;
        if byte ii of recent_line = '\n' then
        {
            byte ii of line := 0;
            break
        }
    }
}


let shutdown_syscall() be
{ out("shutdown called\n");
  on_shutdown();
  finish }

//todo: optimization, return packed word
let time_syscall(code, rn, rv) be
{ let v = vec(7);
  datetime(seconds(), v);
  out("%d/%d/%d ", v!1, v!2, V!0);
  out("%d:%d:%d\n", v!4, v!5, v!6);
  rv ! 0 := (v ! 5);
  ireturn }


let get_line_syscall(code, rn, rv) be
{ let n = rv ! 0;
  let temp_line = rv ! 1;
  get_line(temp_line);
  rv ! 1 := temp_line;
  ireturn }


let create_syscalls() be
{
  let call_gates_address = pt_special_va ! 3;
  call_gates_address -:= (call_gates_address bitand 3);
  out("\n\ncall gates address = 0x%x\n", call_gates_address);
    call_gates_va ! 0 := 0;
    call_gates_va ! 1 := exit_syscall;
    call_gates_va ! 2 := shutdown_syscall;
    call_gates_va ! 2 := exit_syscall;
    call_gates_va ! 3 := time_syscall;
    call_gates_va ! 4 := get_line_syscall;

    assembly
    {
        getsr     r1, $cgbr
        load      r1, [<call_gates_address>]
        setsr     r1, $cgbr
        getsr     r2, $cglen
        load      r2, 5
        setsr     r2, $cglen
    }
}

let print_time() be
{
    let v = vec(7);
    datetime(seconds(), v);
    out("\n%d/%d/%d  ", v!1, v!2, V!0);
    out("\n%d:%d:%d\n", v!4, v!5, v!6)
}


// Handle interrupts

manifest
{
    ptn_bits    = selector 10 : 22,
    pn_bits     = selector 11 : 11,
    offset_bits = selector 11 : 0
}

manifest
{
    iv_none = 0,        iv_memory = 1,      iv_pagefault = 2,   iv_unimpop = 3,
    iv_halt = 4,        iv_divzero = 5,     iv_unwrop = 6,      iv_timer = 7,
    iv_privop = 8,      iv_keybd = 9,       iv_badcall = 10,    iv_pagepriv = 11,
    iv_debug = 12,      iv_intrfault = 13
}

let ihandle_pf(intcode, address, info, pc) be
{
    let ptn = ptn_bits from address;
    let pn  = pn_bits from address;
    let off = offset_bits from address;
    let user_heap_index;
    let user_stack_index;
    let system_heap_index;

    //grow user heap
    //max sizeof user processes' heap is 32 pages (262MB)
    test address > 0x10000000  /\ address < 0x10010000 then
    {
        user_heap_index := infopage_va ! 1;
        out("user heap index = 0x%x\n", user_heap_index);
        user_heap_index +:= 1;
        pt_user_heap_va ! user_heap_index := get_page();
        infopage_va ! 1 := user_heap_index
    }

    //grow user stack
    //max sizeof user processes' stack is 32 pages (262MB)
    else test address > 0x7FFF0000 /\ address < 0x7FFFFFFF then
    {
        user_stack_index := infopage_va ! 3;
        out("user stack index = 0x%x\n", user_stack_index);
        out("stack enlarged @ 0x%x\n", address);
        user_stack_index -:= 1;
        pt_user_stack_va ! user_stack_index := get_page();
        infopage_va ! 3 := user_stack_index
    }
    //grow system heap
    //max sizeof system heap is 32 pages (262MB)
    else test address > 0x0C000000 /\ address < 0x0C010000 then
    {
        system_heap_index := pt_special_va ! 2;
        out("system heap index = 0x%x\n", system_heap_index);
        system_heap_index +:= 1;
        pt_system_heap_va ! system_heap_index := get_page();
        pt_special_va ! 2 := system_heap_index
    }
    else
    {
        out("Page Fault for 0x%x: PT:0x%x, PN:0x%d, OFF:%d\n", address, ptn, pn, off);
        out("PC was 0x%x\n", pc);
        debug 5;
        finish
    }

    ireturn
}


//todo: 200 ms per active process, then switch, pusing flags, registers, sp, fp, pc
let ihandle_timer(intcode, address, info, pc) be
{ let active_process_id = infopage_va ! 4;
  static { n = 0, temp = 0 }
  n +:= 1;
  assembly
  { load    r1, 20000
    setsr   r1, $timer }
  ireturn }

let create_interrupt_handlers() be
{
    intvec_va ! iv_timer     := ihandle_timer;
    intvec_va ! iv_pagefault := ihandle_pf;
    intvec_va ! iv_halt      := ihandle_exit;
    intvec_va ! iv_keybd     := ihandle_keyboard;
    assembly
    {
        getsr  r1, $flags
        cbit   r1, $ip
        setsr  r1, $flags
    }
}


// User shell

let print_commands() be
{
    out("\n\nList of commands:\n");
    out("help\n");
    out("time\n");
    out("echo\n");
    out("run filename\n");
    out("quit/exit\n");
    out("\n\n")
}

let add_exe(file_name) be
{
    let length = strlen(file_name);
    byte length of file_name := '.';
    byte length + 1 of file_name := 'e';
    byte length + 2 of file_name := 'x';
    byte length + 3 of file_name := 'e';
    byte length + 4 of file_name := 0;
    resultis file_name
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



manifest
{
    max_argc = 10
}

let command_line() be
{
    let line = vec(buffer_size);
    let argc = 0;
    let argv = vec(max_argc + 1);
    let ii = 0, jj = 0;

    print_commands();
    while true do
    {
        out("--> ");
        get_line(line);
        argc := 0;
        ii := 0;
        while true do
        {
            while byte ii of line = ' ' do
            {
                ii +:= 1
            }
            if ii >= max_line_length \/ byte ii of line = 0 then
            {
                break;
            }
            argc +:= 1;
            argv ! argc := newvec(string_size);
            if argc >= max_argc then
            {
                break
            }
            jj := 0;
            while jj <= max_strlen \/ ii <= max_line_length do
            {
                byte jj of (argv ! argc) := byte ii of line;
                if byte ii of line = 0 \/ byte ii of line = ' ' then break;
                ii +:= 1;
                jj +:= 1;
            }
            byte jj of (argv ! argc) := 0;
        }
        for ii = 1 to argc do
        {
            out("\n%d: '%s'", ii, argv ! ii)
        }
        test argc = 1 then
        {
            test strcmp(argv ! 1, "quit") \/ strcmp(argv ! 1, "exit") then
            {
                out("\n");
                break
            }
            else test strcmp(argv ! 1, "help") then
            {
                print_commands()
            }
            else test strcmp(argv ! 1, "time") then
            {
                print_time()
            }
            else test strcmp(argv ! 1, "echo") then
            {
                out("\necho: argument(s) needed\n")
            }
            else
            {
                out("\n%s: command not found\n", argv ! 1)
            }
        }
        else test argc > 1 then
        {
            test strcmp(argv ! 1, "echo") then
            {
                out("\n");
                for ii = 2 to argc do
                {
                    out("%s ", argv ! ii)
                }
                out("\n")
            }
            else test strcmp(argv ! 1, "run") then
            {
                create_process(add_exe(argv ! 2))
            }
            else test strcmp(argv ! 1, "mkdir") then
            {
                mkdir(argv ! 2)
            }
            else test strcmp(argv ! 1, "cd") then
            {
                cd(argv ! 2)
            }
            else test strcmp(argv ! 1, "rmdir") then
            {
                rmdir(argv ! 2)
            }
            else test strcmp(argv ! 1, "fcreate") then
            {
                fcreate(argv ! 2)
            }
            else test strcmp(argv ! 1, "fopen") then
            {
                fopen(argv ! 2)
            }
            else test strcmp(argv ! 1, "fclose") then
            {
                fclose(argv ! 2)
            }
            else test strcmp(argv ! 1, "fclose") then
            {
                fdebug(argv ! 2)
            }
            //todo: call fread and fwrite from command line
            //      (requires allocating memory and searching directory)
            else
            {
                out("\n%s: command not found\n", argv ! 1)
            }
        }
        else
        {
            out("\nempty line\n")
        }

        for ii = 1 to argc do
        {
            freevec(argv ! ii);
            argv ! ii := 0
        }
    }
}

let init_newvec() be
{
  newvec := new_vec;
  freevec := free_vec;
  init_heap(0x0C000800);
}

//debugging
let print_occupied_pages() be
{
    let count = 1;
    out("\nPages in use:\n");
    for ii = 1 to num_pages do
    {
        if ((freelist_va ! ii) bitand 4) <> 0 then
        {
           out("%d: (%d:) 0x%x\n", count, ii, freelist_va ! ii);
           count +:= 1
        }
    }
    out("\n\n");
}

let start() be
{
    let kb_buffer   = vec(buffer_size);
    let line_buffer = vec(buffer_size);
    let temp;

    static { os_start = 1, reformat_disc = false }

    assembly
    {
        getsr    r1, $flags
        sbit     r1, $sys
        setsr    r1, $flags
    }

    if os_start = 1 do
    {
        create_interrupt_handlers();
        create_syscalls();
        set_num_pages();
        os_start := 0
    }
    init_newvec();
    on_start(reformat_disc);
    set_keyboard_buffer(kb_buffer, line_buffer, buffer_size);
    infopage_va ! 4 := 0; //current process ID
    command_line()
}
