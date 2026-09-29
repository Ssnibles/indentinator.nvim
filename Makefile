NVIM ?= nvim

.PHONY: test luacheck stylua check

test:
	@./tests/run.sh

luacheck:
	luacheck lua plugin tests

stylua:
	stylua --check lua plugin tests

check: luacheck stylua test
