" Vim filetype plugin
" Language:     Intel HEX
" Last Change:  2024 Oct 19
" License:      https://unlicense.org
" URL:          https://github.com/matveyt/intelhex.vim

let s:cpo_save = &cpo
set cpo&vim

" corrupted line
let s:fatal_error = [
    \ ['len == 0', 'line is empty'],
    \ ['len < 11', 'line is too short'],
    \ ['line[0] != '':''', 'missing colon'],
    \ ['line[1:] =~ ''\X''', 'extra characters on line'],
    \ ['len % 2 == 0', 'odd number of digits'],
\ ]

" recoverable error
let s:nonfatal_error = [
    \ ['reclen != chunk[0]', 'reclen mismatch'],
    \ ['intelhex#checksum(chunk) != 0', 'checksum mismatch'],
    \ ['rectyp != 1 && lineno == lcount', 'missing EOF'],
\ ]

" rectyp specific
let s:rectyp_error = [
    "\ rectyp == 0
    \ [
        \ ['reclen == 0', 'empty data record'],
        \ ['(offset + reclen) > (1 << 16)', 'data wraps over 64K'],
    \ ],
    "\ rectyp == 1
    \ [
        \ ['lineno < lcount', 'premature EOF ignored'],
        \ ['reclen != 0 || offset != 0 || chunk[-1] != 255', 'malformed EOF record'],
    \ ],
    "\ rectyp == 2
    \ [
        \ ['self.bits == 32', '16-bit record not allowed here'],
        \ ['reclen != 2 || offset != 0', 'bad 16-bit segment'],
    \ ],
    "\ rectyp == 3
    \ [
        \ ['self.bits == 32', '16-bit record not allowed here'],
        \ ['self.has_entry()', 'duplicate entry point'],
        \ ['reclen != 4 || offset != 0', 'bad 16-bit entry point'],
        \ ['(high << 4) + low >= (1 << 20)', '16-bit entry point over 1 MB'],
    \ ],
    "\ rectyp == 4
    \ [
        \ ['self.bits == 16', '32-bit record not allowed here'],
        \ ['reclen != 2 || offset != 0', 'bad 32-bit segment'],
    \ ],
    "\ rectyp == 5
    \ [
        \ ['self.bits == 16', '32-bit record not allowed here'],
        \ ['self.has_entry()', 'duplicate entry point'],
        \ ['reclen != 4 || offset != 0', 'bad 32-bit entry point'],
    \ ],
\ ]

function! intelhex#new(opts = {}) abort
    let l:code = #{
        \ data_size: 16,
        \ check_only: v:false,
        \ max_errors: 50,
        \ bits: 8,
        \ entry: [0, 0],
        \ vaddr: [v:numbermax, 0],
        \ chunk_list: [],
        \ error_list: [],
        \ adjust: 0,
        \ last_lineno: 0,
        \ last_segment: 0,
        \ last_size: 0,
    \ } ->extend(a:opts)

    function l:code.has_bytes() abort
        return !self.check_only && self.vaddr[1] > self.vaddr[0]
    endfunction

    function l:code.has_entry() abort
        return self.entry[0] || self.entry[1]
    endfunction

    function l:code.vsize() abort
        return max([self.vaddr[1] - self.vaddr[0], 0])
    endfunction

    function l:code.blob(filler = 255) abort
        if !self.has_bytes()
            return 0z
        endif
        let l:blob = printf('0z%02X', and(a:filler, 255))->eval()->repeat(self.vsize())
        for l:chunk in self.chunk_list
            if l:chunk.size > 0
                let l:start = l:chunk.segment + l:chunk.offset - self.vaddr[0]
                let l:blob[l:start : l:start + l:chunk.size - 1] = l:chunk.bytes
            endif
        endfor
        return l:blob
    endfunction

    function l:code.add_chunk(chunk) abort
        let self.vaddr[0] = min([a:chunk.segment + a:chunk.offset, self.vaddr[0]])
        let self.vaddr[1] = max([a:chunk.segment + a:chunk.offset + a:chunk.size,
            \ self.vaddr[1]])

        if empty(self.chunk_list)
            call add(self.chunk_list, a:chunk)
        else
            let l:tail = self.chunk_list[-1]
            if l:tail.segment == a:chunk.segment &&
                \ l:tail.offset + l:tail.size == a:chunk.offset
                let l:tail.bytes += a:chunk.bytes
                let l:tail.size += a:chunk.size
                " appending to small chunk?
                let self.adjust += 0 < self.last_size && self.last_size < self.data_size
            else
                call add(self.chunk_list, a:chunk)
                " unsorted chunk?
                let self.adjust += l:tail.segment + l:tail.offset + l:tail.size >
                    \ a:chunk.segment + a:chunk.offset
            endif
        endif

        let self.last_size = a:chunk.size
        " data record longer than data_size?
        let self.adjust += self.last_size > self.data_size
    endfunction

    function l:code.add_error(lineno, msg) abort
        if self.last_lineno
            let l:str = printf('#%d[%d] %s', self.last_lineno + a:lineno, a:lineno,
                \ a:msg)
        else
            let l:str = printf('#%d %s', a:lineno, a:msg)
        endif
        call add(self.error_list, l:str)
    endfunction

    return l:code
endfunction

function s:compile(...) abort dict
    if len(self.error_list) >= self.max_errors
        " compile failed
        return 1
    endif

    function! s:eval(_, v) abort closure
        return eval(a:v[0])
    endfunction

    function! s:test(check_list) abort closure
        let l:result = a:check_list->indexof(funcref('s:eval'))
        if l:result >= 0
            call self.add_error(l:lineno, a:check_list[l:result][1])
        endif
        return l:result
    endfunction

    " read line
    let [l:xoffset, l:lcount, l:lineno, l:line] = a:000
    let l:lineno += 1
    let l:len = strlen(l:line)
    if s:test(s:fatal_error) >= 0
        " skip corrupted line
        return
    endif

    " split into fields
    let l:chunk = eval('0z'..l:line[1:])
    let l:reclen = len(l:chunk) - 5
    let l:offset = (l:chunk[1] << 8) + (l:chunk[2])
    let l:rectyp = l:chunk[3]
    call s:test(s:nonfatal_error)

    if l:rectyp == 0
        " data record
        if s:test(s:rectyp_error[l:rectyp]) < 0
            call self.add_chunk(#{ segment: self.last_segment,
                \ offset: l:xoffset + l:offset, size: l:reclen,
                \ bytes: self.check_only ? 0z : l:chunk[4 : -2] })
        endif
    elseif l:rectyp == 1
        " eof record
        call s:test(s:rectyp_error[l:rectyp])
    elseif l:rectyp == 2
        " extended segment address (assume 16-bit)
        let l:high = (l:chunk[-3] << 12) + (l:chunk[-2] << 4)
        if s:test(s:rectyp_error[l:rectyp]) < 0
            let self.bits = 16
            let self.last_segment = l:high
        endif
    elseif l:rectyp == 3
        " start segment address (assume 16-bit)
        let l:high = (l:chunk[-5] << 8) + l:chunk[-4]
        let l:low  = (l:chunk[-3] << 8) + l:chunk[-2]
        if s:test(s:rectyp_error[l:rectyp]) < 0
            let self.bits = 16
            let self.entry = [l:xoffset + l:low, l:high]
        endif
    elseif l:rectyp == 4
        " extended linear address 32-bit
        let l:high = (l:chunk[-3] << 24) + (l:chunk[-2] << 16)
        if s:test(s:rectyp_error[l:rectyp]) < 0
            let self.bits = 32
            let self.last_segment = l:high
        endif
    elseif l:rectyp == 5
        " start linear address 32-bit
        let l:high = (l:chunk[-5] << 8) + l:chunk[-4]
        let l:low  = (l:chunk[-3] << 8) + l:chunk[-2]
        if s:test(s:rectyp_error[l:rectyp]) < 0
            let self.bits = 32
            let self.entry = [l:xoffset + l:low, l:high]
        endif
    else
        " unknown record type
        call self.add_error(l:lineno, 'unknown record type')
    endif
endfunction

function! intelhex#checksum(...) abort
    let l:sum = 0
    for l:item in a:000
        let l:sum += (type(l:item) is v:t_number) ? (l:item + (l:item >> 8)) :
            \ reduce(l:item, { acc, v -> acc + v })
    endfor
    return and(-l:sum, 255)
endfunction

function! intelhex#compile(code, xoffset = 0, buf = '%') abort
    let l:buf = (type(a:buf) is v:t_list) ? a:buf : getbufline(a:buf, 1, '$')
    let l:lcount = len(l:buf)
    if l:lcount > 0
        let l:adjust = a:code.adjust
        call indexof(l:buf, function('s:compile', [a:xoffset, l:lcount], a:code))
        let a:code.last_lineno += l:lcount
        if a:code.adjust > l:adjust
            " sort and merge chunk list
            call sort(a:code.chunk_list, { v1, v2 ->
                \ v1.segment + v1.offset - v2.segment - v2.offset })
            let [l:old_chunk_list, a:code.chunk_list] = [a:code.chunk_list, []]
            while !empty(l:old_chunk_list)
                call a:code.add_chunk(remove(l:old_chunk_list, 0))
            endwhile
        endif
    endif
    return a:code
endfunction

function! intelhex#show_info(code) abort
    let l:width = (a:code.bits == 32) ? 8 : (a:code.bits == 16) ? 5 : 4

    echo printf('Bits: %d', a:code.bits)
    echo printf('Need adjustment: %s', a:code.adjust > 0 ? 'YES' : 'NO')
    echo printf('Virtual range: %0*X-%0*X (%d bytes)', l:width, a:code.vaddr[0],
        \ l:width, a:code.vaddr[1] - 1, a:code.vsize())
    echo printf('Entry point: %s', a:code.has_entry() ? printf('%04X%s%04X',
        \ a:code.entry[1], (a:code.bits != 16) ? '' : ':', a:code.entry[0]) : 'NONE')

    echo "\nChunks:"
    for l:chunk in a:code.chunk_list
        echo printf('  %s%04X %d bytes', (a:code.bits == 8) ? '' :
            \ printf('%0*X:', l:width, l:chunk.segment), l:chunk.offset, l:chunk.size)
    endfor

    echo printf("\nTotal errors: %d", len(a:code.error_list))
    for l:msg in a:code.error_list
        echo l:msg
    endfor
endfunction

function! intelhex#dump(code, opts = {}) abort
    if !a:code.has_bytes()
        return
    endif

    let l:opts = #{
        \ buf: '%',
        \ force8: 0,
        \ replace: 0,
    \ } ->extend(a:opts)

    let l:force8 = l:opts.force8 && (a:code.bits != 8)
    if l:opts.replace == 0
        " append only
        let l:replace = 0
    else
        if l:opts.replace < 0 && a:code.adjust == 0 && !l:force8
            " nothing to do
            return intelhex#show_info(a:code)
        endif
        " replace buffer
        let l:replace = 1
    endif

    if l:replace
        silent call deletebufline(l:opts.buf, 1, '$')
    endif

    let l:segment = 0
    for l:chunk in a:code.chunk_list
        if !l:force8 && l:chunk.segment != l:segment
            " new segment
            let l:segment = l:chunk.segment
            if a:code.bits == 32
                let [l:offset, l:rectyp] = [and(l:segment >> 16, 0xFFFF), 4]
            else
                let [l:offset, l:rectyp] = [and(l:segment >> 4, 0xFFFF), 2]
            endif
            call appendbufline(l:opts.buf, '$',
                \ printf(':020000%02X%04X%02X', l:rectyp, l:offset,
                    \ intelhex#checksum(0x02, l:rectyp, l:offset)))
        endif

        let [l:len, l:offset] = [l:chunk.size, 0]
        while l:len > 0
            let l:line_size = min([l:len, a:code.data_size])
            let l:line_offset = l:chunk.offset + l:offset
            let l:bytes = l:chunk.bytes[l:offset : l:offset + l:line_size - 1]
            let l:data = blob2list(l:bytes)->map({ _, v -> printf('%02X', v) })->join('')
            call appendbufline(l:opts.buf, '$',
                \ printf(':%02X%04X00%s%02X', l:line_size, l:line_offset, l:data,
                    \ intelhex#checksum(l:line_size, l:line_offset, l:bytes)))
            let l:len -= l:line_size
            let l:offset += l:line_size
        endwhile
    endfor

    if !l:force8 && a:code.has_entry()
        " entry point
        let l:rectyp = (a:code.bits == 32) ? 5 : 3
        call appendbufline(l:opts.buf, '$',
            \ printf(':040000%02X%04X%04X%02X', l:rectyp, a:code.entry[1],
                \ a:code.entry[0],
                \ intelhex#checksum(0x04, l:rectyp, a:code.entry[0], a:code.entry[1])))
    endif
    call appendbufline(l:opts.buf, '$', ':00000001FF')

    if l:replace
        call deletebufline(l:opts.buf, 1)
    endif
    call intelhex#show_info(a:code)
endfunction

let &cpo = s:cpo_save
unlet s:cpo_save
