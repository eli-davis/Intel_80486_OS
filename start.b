import "io"


static { next_free_page, last_page, num_pages }

let set_first_and_last_page() be
{
    let first_word = (! 0x101);
    let last_word  = (! 0x100) - 1;
    next_free_page := (first_word + 2047) >> 11;
    last_page      := last_word >> 11;
    out("%d\n", last_page)
}

let get_page_address() be
{
    let p = next_free_page << 11;
    if next_free_page > last_page then
    {
        outs("OUT OF MEMORY BEFORE VM STARTED\n");
        finish
    }
    next_free_page +:= 1;
    assembly
    {
        clrpp [<p>]
    }
    resultis p
}


let tape_load(tape_number, file_name, read_or_write) be
{
    let load = devctl(DC_TAPE_LOAD, tape_number, file_name, read_or_write);
    if load <= 0 then
    {
        out("tape load failed for tape %d\n", tape_number)
    }
    resultis load
}

let tape_check(tape_number) be
{
    let read_or_write = devctl(DC_TAPE_CHECK, tape_number);
    if read_or_write = 0 then
    {
        out("tape check failed for tape %d\n", tape_number);
    }
    resultis read_or_write
}

manifest
{
    tape_one        = 1,
    words_per_block = 128,
    bytes_per_block = 512
}

let load_os(exe_name) be
{
    let call_gates    = get_page_address();
    let interrupt_vec = get_page_address();
    let pgdir         = get_page_address();
    let freelist      = get_page_address();
    let pt_code       = get_page_address();
    let pt_heap       = get_page_address();
    let pt_stack      = get_page_address();
    let pt_special    = get_page_address();

    let infopage      = get_page_address();
    let pt_user_heap  = get_page_address();
    let pt_user_code  = get_page_address();
    let pt_user_stack = get_page_address();

    let system_code   = get_page_address();
    let system_heap   = get_page_address();
    let system_stack  = get_page_address();

    let available_blocks = 16, pt_code_index = 1;
    let r = bytes_per_block, bytes_read = 0;

    assembly
    {
        load  r1, [<call_gates>]
        setsr r1, $cgbr
        load  r1, [<interrupt_vec>]
        setsr r1, $intvec
    }

    pt_code  ! 0    := system_code  bitor 1;
    pt_heap  ! 1    := system_heap  bitor 1;
    pt_stack ! 2047 := system_stack bitor 1;

    //read in system code
    tape_load(tape_one, exe_name, 'R');
    tape_check(tape_one);
    while r = bytes_per_block do
    {
        r := devctl(DC_TAPE_READ, 1, system_code);
        if r < 0 then
        {
            out("error %d while reading tape '%s'\n", r, exe_name);
            finish
        }
        bytes_read +:= r;
        available_blocks -:= 1;
        system_code +:= words_per_block;
        if available_blocks = 0 then
        {
            system_code := get_page_address();
            pt_code ! pt_code_index := system_code bitor 1;
            pt_code_index +:= 1;
            available_blocks := 16
        }
    }
    out("Loaded %d bytes, %d pages of '%s'\n", bytes_read, pt_code_index, exe_name);

    freelist      ! 0 := freelist bitor 1;
    infopage      ! 0 := infopage bitor 1;
    pt_heap       ! 0 := pt_heap bitor 1;
    pt_user_heap  ! 0 := pt_user_heap bitor 1;
    pt_user_code  ! 0 := pt_user_code bitor 1;
    pt_user_stack ! 0 := pt_user_stack bitor 1;

    pgdir ! 0x010 := freelist bitor 1;
    pgdir ! 0x020 := infopage bitor 1;
    pgdir ! 0x030 := pt_heap bitor 1;
    pgdir ! 0x040 := pt_user_heap bitor 1;
    pgdir ! 0x100 := pt_user_code bitor 1;
    pgdir ! 0x1FF := pt_user_stack bitor 1;
    pgdir ! 0x200 := pt_code bitor 1;
    pgdir ! 0x2FF := pt_stack bitor 1;
    pgdir ! 0x300 := pt_special bitor 1;

    //system stuff
    pt_special ! 0 := pt_special bitor 1;
    pt_special ! 1 := pgdir bitor 1;
    pt_special ! 2 := 1; //system heap index
    pt_special ! 3 := call_gates bitor 1; //syscalls
    pt_special ! 4 := interrupt_vec bitor 1;

    //create freelist
    num_pages := last_page - next_free_page + 1;
    for ii = 1 to num_pages do
    {
        freelist ! ii := get_page_address() bitor 1;
    }
    out("num pages = %d\n", num_pages);

    resultis pgdir;
}

//debugging
let print_memory_map(pgdir_address) be
{
    out("\npgdir address = 0x%x\n\n", pgdir_address);
    for ptn = 0 to 1023 do
    {
        if pgdir_address ! ptn <> 0 then
        {
            let pt_address = (pgdir_address ! ptn) bitand 0xFFFFF800; //clear last 11 bits from page table address
            let pt_va = ptn << 22;
            out("0x%x ! 0x%x = 0x%x\n", pgdir_address, ptn, pt_address);
            out("for VAs: 0x%x to 0x%x  ", pt_va, ((ptn + 1) << 22) - 1);
            for pn = 0 to 2047 do
            {
                if pt_address ! pn bitand 1 then
                {
                    let page_address = (pt_address ! pn) bitand 0xFFFF800;
                    let page_va = (ptn << 22) + (pn << 11);
                    out("  0x%x ! 0x%x = 0x%x", pt_address, pn, page_address);
                    out("  for VAs: 0x%x to 0x%x", page_va, page_va+2047);
                }
                out("\n");
            }
        }
    }
}

let start() be
{
    let pgdir_address;
    set_first_and_last_page();
    pgdir_address := load_os("os.exe");
    // debugging
    //out("\n\n");
    //for i = 0 to 1023 do
    //{
    //      if i rem 16 = 0 then out("\n");
    //      test pgdir_address ! i = 0 then out("0x__")
    //      else out("0x%10x ", i << 22)
    //}
    //print_memory_map(pgdir_address);

    assembly
    {
        load      r1, [<pgdir_address>]
        load      sp, 0x0000
        loadh     sp, 0xC000
        load      fp, sp
        setsr     r1, $pdbr
        getsr     r1, $flags
        sbit      r1, $vm
        load      r2, 0x0000
        loadh     r2, 0x8000
        flagsj    r1, r2
    }
    outs("Don't get here!\n");
}

