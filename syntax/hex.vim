" Vim syntax file
" Language:     Intel HEX
" Last Change:  2024 Oct 19
" License:      https://unlicense.org
" URL:          https://github.com/matveyt/intelhex.vim

if exists('b:current_syntax')
    finish
endif
let b:current_syntax = 'hex'

syn match hexError /\X\+/
syn match hexRecMark /^:/ nextgroup=hexRecLen
syn match hexRecLen /\x\x/ nextgroup=hexLoadOffset contained
syn match hexLoadOffset /\x\x\x\x/ nextgroup=hexRecData,hexRecOther contained
syn match hexRecData /00/ nextgroup=hexData1,hexChkSum contained
syn match hexRecOther /0[1-5]/ nextgroup=hexData1,hexChkSum contained
syn match hexData1 /\x\x/ nextgroup=hexData2,hexChkSum contained
syn match hexData2 /\x\x/ nextgroup=hexData1,hexChkSum contained
syn match hexChkSum /\x\x$/ contained

hi def link hexError Error
hi def link hexRecMark Special
hi def link hexRecLen Special
hi def link hexLoadOffset Constant
hi def link hexRecData Special
hi def link hexRecOther Comment
hi def link hexData1 NONE
hi def link hexData2 Constant
hi def link hexChkSum Comment
