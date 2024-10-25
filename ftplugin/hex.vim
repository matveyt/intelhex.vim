" Vim filetype plugin
" Language:     Intel HEX
" Last Change:  2024 Oct 25
" License:      https://unlicense.org
" URL:          https://github.com/matveyt/intelhex.vim

if exists('b:did_ftplugin')
    finish
endif
let b:did_ftplugin = 1

let s:cpo_save = &cpo
set cpo&vim

let b:undo_ftplugin = 'setl ai< si< fo< com< cms< tw<'
setlocal noautoindent nosmartindent textwidth=43
setlocal comments= commentstring= formatoptions=

nnoremap <buffer>g? <cmd>Validate<CR>
nnoremap <buffer>gn <cmd>Normalize<CR>
nnoremap <buffer>g8 <cmd>Normalize!<CR>
nnoremap <buffer>gj <cmd>call search('^:\x\{6}0[1-5]', 'ewz')<CR>
nnoremap <buffer>gk <cmd>call search('^:\x\{6}0[1-5]', 'bewz')<CR>

command! -buffer -bar -complete=file -nargs=+ Bin2Hex
    \ call intelhex#new().new_chunk(#{ segment: 0, offset: 0,
        \ bytes: readblob(<f-args>) }).dump()
command! -buffer -bar -complete=file -nargs=+ Hex2Bin
    \ call intelhex#new().compile().blob()->writefile(<f-args>)
command! -buffer -bar -bang Normalize
    \ call intelhex#new().compile().dump(<bang>v:false, v:true)
command! -buffer -bar Validate
    \ call intelhex#new().compile().show()

let &cpo = s:cpo_save
unlet s:cpo_save
