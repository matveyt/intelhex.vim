" Vim filetype plugin
" Language:     Intel HEX
" Last Change:  2024 Oct 25
" License:      https://unlicense.org
" URL:          https://github.com/matveyt/intelhex.vim

let s:cpo_save = &cpo
set cpo&vim

" corrupted line
let s:error_line_1 = [
    \ ['len == 0', 'empty line'],
    \ ['len < 11', 'line is too short'],
    \ ['line[0] != '':''', 'missing colon'],
    \ ['line[1:] =~ ''\X''', 'extra characters on line'],
    \ ['len % 2 == 0', 'odd number of digits'],
\ ]

" recoverable line
let s:error_line_2 = [
    \ ['reclen != chunk[0]', 'reclen mismatch'],
    \ ['intelhex#checksum(chunk) != 0', 'wrong checksum'],
\ ]

" rectyp specific
let s:error_rectyp = [
    "\ rectyp == 0
    \ [
        \ ['reclen == 0', 'empty data record'],
        \ ['(offset + reclen) > (1 << 16)', 'data wraps over 64K'],
    \ ],
    "\ rectyp == 1
    \ [
        \ ['reclen != 0 || offset != 0 || chunk[-1] != 255', 'malformed EOF record'],
        \ ['self.eof_lineno_1 != 0 && self.eof_lineno_2 == self.last_lineno',
            \ 'duplicate EOF'],
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

function! intelhex#new(data_size = 16, skip_max = 50) abort
    let l:code = #{
        "\ in param
        \ data_size: a:data_size,
        \ skip_max: (a:skip_max >= 0) ? a:skip_max : v:numbermax,
        "\ data
        \ bits: 8,
        \ entry_lo: 0,
        \ entry_hi: 0,
        \ vaddr_lo: v:numbermax,
        \ vaddr_hi: 0,
        \ chunk_list: [],
        \ error_list: [],
        "\ internal data
        \ skip_count: 0,
        \ adjust: 0,
        \ eof_lineno_1: 0,
        \ eof_lineno_2: 0,
        \ last_lineno: 0,
        \ last_segment: 0,
        \ last_size: a:data_size,
        "\ internal methods
        \ new_chunk: function('s:ihex_new_chunk'),
        \ new_error: function('s:ihex_new_error'),
        "\ method
        \ blob: function('s:ihex_blob'),
        \ compile: function('s:ihex_compile'),
        \ dump: function('s:ihex_dump'),
        \ show: function('s:ihex_show'),
    \ }

    function l:code.has_entry() abort
        return self.entry_lo || self.entry_hi
    endfunction

    function l:code.vsize() abort
        return max([self.vaddr_hi - self.vaddr_lo, 0])
    endfunction

    function l:code.organized() abort
        return self.adjust == 0 && empty(self.error_list)
    endfunction

    function l:code.format(hi, lo = v:null) abort
        return (self.bits == 8) ? printf('%04X', a:lo ?? a:hi) :
            \ (a:lo is v:null) ? printf('%0*X', (self.bits == 32) ? 8 : 5, a:hi) :
            \ printf('%0*X:%04X', (self.bits == 32) ? 8 : 4, a:hi, a:lo)
    endfunction

    return l:code
endfunction

function! intelhex#checksum(...) abort
    let l:sum = 0
    for l:item in a:000
        let l:sum += (type(l:item) is v:t_number) ? (l:item + (l:item >> 8)) :
            \ reduce(l:item, { acc, v -> acc + v })
    endfor
    return and(-l:sum, 255)
endfunction

function s:ihex_new_chunk(chunk) abort dict
    let l:chunk_size = len(a:chunk.bytes)
    let self.vaddr_lo = min([a:chunk.segment + a:chunk.offset, self.vaddr_lo])
    let self.vaddr_hi = max([a:chunk.segment + a:chunk.offset + l:chunk_size,
        \ self.vaddr_hi])

    if empty(self.chunk_list)
        call add(self.chunk_list, a:chunk)
    else
        let l:tail = self.chunk_list[-1]
        if a:chunk.segment != l:tail.segment
            call add(self.chunk_list, a:chunk)
            " unsorted segment?
            let self.adjust += (a:chunk.segment < l:tail.segment)
        else
            let l:diff = a:chunk.offset - l:tail.offset
            let l:tail_size = len(l:tail.bytes)
            if l:diff < 0
                " unsorted chunks
                call add(self.chunk_list, a:chunk)
                let self.adjust += 1
            elseif l:diff < l:tail_size
                " overlapping chunks
                if l:diff + l:chunk_size <= l:tail_size
                    " new chunk within the old one
                    let l:tail.bytes[l:diff : l:diff + l:chunk_size - 1] = a:chunk.bytes
                elseif l:diff == 0
                    " new chunk replaces the old one
                    let self.chunk_list[-1] = a:chunk
                else
                    " overlap and extend
                    let l:tail.bytes = l:tail.bytes->slice(0, l:diff) + a:chunk.bytes
                endif
                let self.adjust += 1
            elseif l:diff == l:tail_size
                " merge chunks
                let l:tail.bytes += a:chunk.bytes
                " appending to small chunk?
                let self.adjust += (self.last_size < self.data_size)
            else
                " sorted chunks
                call add(self.chunk_list, a:chunk)
            endif
        endif
    endif

    " data record longer than data_size?
    let self.adjust += (l:chunk_size > self.data_size)
    let self.last_size = l:chunk_size
    return self
endfunction

function s:ihex_new_error(lineno, msg, skipline = v:true) abort dict
    let self.skip_count += !!a:skipline
    let l:msg = printf('%s[%d%s] %s', a:skipline ? 'Error' : 'Warning',
        \ self.last_lineno + a:lineno,
        \ self.last_lineno ? printf(',%d', a:lineno) : '', a:msg)
    call add(self.error_list, l:msg)
endfunction

function s:ihex_blob(filler = 0xFF) abort dict
    let l:result = 0z
    if self.vsize() > 0
        let l:result = add(l:result, and(a:filler, 0xFF))->repeat(self.vsize())
        for l:chunk in self.chunk_list
            let l:offset = l:chunk.segment + l:chunk.offset - self.vaddr_lo
            let l:result[l:offset : l:offset + len(l:chunk.bytes) - 1] = l:chunk.bytes
        endfor
    endif
    return l:result
endfunction

function s:ihex_line(...) abort dict
    if self.skip_count > self.skip_max
        " abort compile
        return 1
    endif

    function! s:eval(_, v) abort closure
        return eval(a:v[0])
    endfunction

    function! s:test(check_list, skipline = v:true) abort closure
        let l:result = indexof(a:check_list, funcref('s:eval'))
        if l:result >= 0
            call self.new_error(l:lineno, a:check_list[l:result][1], a:skipline)
        endif
        return l:result
    endfunction

    " read line
    let [l:base16, l:lineno, l:line] = a:000
    let l:lineno += 1 " 1-based
    let l:len = strlen(l:line)
    if s:test(s:error_line_1) >= 0
        return
    endif

    " split into fields
    let l:chunk = eval('0z'..l:line[1:])
    let l:reclen = len(l:chunk) - 5
    let l:offset = (l:chunk[1] << 8) + (l:chunk[2])
    let l:rectyp = l:chunk[3]
    call s:test(s:error_line_2, 0)

    if l:rectyp == 0
        " data record
        if s:test(s:error_rectyp[l:rectyp]) < 0
            call self.new_chunk(#{ bytes: l:chunk[4 : -2], offset: l:base16 + l:offset,
                \ segment: self.last_segment })
        endif
    elseif l:rectyp == 1
        " eof record
        if s:test(s:error_rectyp[l:rectyp]) < 0
            let [self.eof_lineno_1, self.eof_lineno_2] = [l:lineno, self.last_lineno]
        endif
    elseif l:rectyp == 2
        " extended segment address (assume 16-bit)
        let l:hi = (l:chunk[-3] << 12) + (l:chunk[-2] << 4)
        if s:test(s:error_rectyp[l:rectyp]) < 0
            let self.bits = 16
            let self.last_segment = l:hi
        endif
    elseif l:rectyp == 3
        " start segment address (assume 16-bit)
        let l:hi = (l:chunk[-5] << 8) + l:chunk[-4]
        let l:lo = (l:chunk[-3] << 8) + l:chunk[-2]
        if s:test(s:error_rectyp[l:rectyp]) < 0
            let self.bits = 16
            let [self.entry_lo, self.entry_hi] = [l:base16 + l:lo, l:hi << 4]
        endif
    elseif l:rectyp == 4
        " extended linear address 32-bit
        let l:hi = (l:chunk[-3] << 24) + (l:chunk[-2] << 16)
        if s:test(s:error_rectyp[l:rectyp]) < 0
            let self.bits = 32
            let self.last_segment = l:hi
        endif
    elseif l:rectyp == 5
        " start linear address 32-bit
        let l:hi = (l:chunk[-5] << 8) + l:chunk[-4]
        let l:lo = (l:chunk[-3] << 8) + l:chunk[-2]
        if s:test(s:error_rectyp[l:rectyp]) < 0
            let self.bits = 32
            let [self.entry_lo, self.entry_hi] = [l:base16 + l:lo, l:hi << 16]
        endif
    else
        " unknown record type
        call self.new_error(l:lineno, 'unknown record type')
    endif
endfunction

function s:ihex_compile(buf = '%', base16 = 0) abort dict
    let l:is_list = type(a:buf) is v:t_list
    let l:buf = l:is_list ? a:buf : getbufline(a:buf, 1, '$')
    let l:lcount = len(l:buf)
    if l:lcount > 0
        let l:adjust = self.adjust
        call indexof(l:buf, function('s:ihex_line', [a:base16], self))
        " sort and merge chunk list
        if self.adjust > l:adjust
            call sort(self.chunk_list, { v1, v2 ->
                \ (v1.segment - v2.segment) ?? (v1.offset - v2.offset) })
            let [l:old_chunk_list, self.chunk_list] = [self.chunk_list, []]
            while !empty(l:old_chunk_list)
                call self.new_chunk(remove(l:old_chunk_list, 0))
            endwhile
        endif
        if !l:is_list && (l:lcount != self.eof_lineno_1 ||
            \ self.last_lineno != self.eof_lineno_2)
            call self.new_error(l:lcount, 'missing EOF', v:false)
        endif
        let self.last_lineno += l:lcount
    endif
    return self
endfunction

function s:ihex_dump(force8 = v:false, replace = v:false) abort dict
    if self.vsize() <= 0
        return
    endif

    let l:force8 = a:force8 && (self.bits > 8)
    if a:replace && !l:force8 && self.organized()
        " nothing to do
        return self.show()
    endif

    if a:replace
        silent call deletebufline('%', 1, '$')
    endif

    let l:lcurr = line('.')
    let l:segment = 0
    for l:chunk in self.chunk_list
        if !l:force8 && l:chunk.segment != l:segment
            " segment output
            let l:segment = l:chunk.segment
            if self.bits == 32
                let l:rectyp = 4
                let l:address = l:segment >> 16
            else
                let l:rectyp = 2
                let l:address = l:segment >> 4
            endif
            call append(l:lcurr, printf(':020000%02X%04X%02X', l:rectyp, l:address,
                \ intelhex#checksum(2, l:rectyp, l:address)))
            let l:lcurr += 1
        endif

        " chunk output
        for l:ix in range(0, len(l:chunk.bytes) - 1, self.data_size)
            let l:reclen = min([self.data_size, len(l:chunk.bytes) - l:ix])
            let l:address = l:chunk.offset + l:ix
            let l:bytes = l:chunk.bytes->slice(l:ix, l:ix + l:reclen)
            let l:xdigits = blob2list(l:bytes)->map({ _, v -> printf('%02X', v) })
            call append(l:lcurr, printf(':%02X%04X00%s%02X', l:reclen, l:address,
                \ l:xdigits->join(''), intelhex#checksum(l:reclen, l:address, l:bytes)))
            let l:lcurr += 1
        endfor
    endfor

    if !l:force8 && self.has_entry()
        " entry point
        if self.bits == 32
            let l:rectyp = 5
            let l:address = self.entry_hi >> 16
        else
            let l:rectyp = 3
            let l:address = self.entry_hi >> 4
        endif
        call append(l:lcurr, printf(':040000%02X%04X%04X%02X', l:rectyp, l:address,
            \ self.entry_lo, intelhex#checksum(4, l:rectyp, l:address, self.entry_lo)))
        let l:lcurr += 1
    endif
    call append(l:lcurr, ':00000001FF')

    if a:replace
        call deletebufline('%', 1)
    endif
    return self
endfunction

function s:ihex_show() abort dict
    echo printf('Bits: %d', self.bits)
    echo printf('Organized: %s', self.organized() ? 'Yes' : 'No')
    echo printf('Virtual range: %s-%s (%d bytes)', self.format(self.vaddr_lo),
        \ self.format(self.vaddr_hi - 1), self.vsize())
    echo printf('Entry point: %s', !self.has_entry() ? 'None' :
        \ self.format(self.entry_hi, self.entry_lo))

    echo "\nChunks:"
    for l:chunk in self.chunk_list
        echo printf('  %s (%d bytes)', self.format(l:chunk.segment, l:chunk.offset),
            \ len(l:chunk.bytes))
    endfor

    echo printf("\nLines compiled: %d", self.last_lineno)
    echo printf('Lines skipped: %d', self.skip_count)
    echo printf('Total errors: %d', len(self.error_list))
    for l:msg in self.error_list
        echo l:msg
    endfor

    return self
endfunction

let &cpo = s:cpo_save
unlet s:cpo_save
