" Vim filetype plugin
" Language:     Intel HEX
" Last Change:  2024 Oct 18
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

nnoremap <buffer>g8 <cmd>Normalize<CR>
nnoremap <buffer>g? <cmd>Validate<CR>

command! -buffer -bar -nargs=1 Binary
    \ call intelhex#new()->intelhex#compile().blob()->writefile(<q-args>)
command! -buffer -bar -bang Normalize
    \ call intelhex#new()->intelhex#compile()
    \   ->intelhex#dump(#{ force8: <bang>0, replace: -1 })
command! -buffer -bar Validate
    \ call intelhex#new(#{ check_only: 1 })->intelhex#compile()->intelhex#show_info()

let &cpo = s:cpo_save
unlet s:cpo_save
