# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 André Valentin <avalentin@marcant.net>
#
# wwand-esim-transfer: precompile the ucode to bytecode, exactly as the wwand
# tree does (wwand CMakeLists.txt, whose rules this follows):
#   * one compiler run per file; every module this package and its imports
#     name is passed as `dynlink=`, so files compile independently and the VM
#     resolves the imports at runtime through /usr/share/ucode;
#   * imports namespaced (`wwand.esim_transfer.sha1`), never relative — a
#     relative import would be inlined as a second copy of the module;
#   * no `-` in module paths (the dotted runtime resolver cannot map it);
#   * `-s` so the bytecode does not embed the build path;
#   * the compiling ucode must be the runtime's revision (bytecode is
#     VM-locked): the package build passes the SDK host ucode.
#
# What stays SOURCE: the two require()d entry points wwand loads by path —
# plugins/esim_transfer.uc (plugins.uc) and ctl/transfer.uc (wwandctl). A
# require()d file is parsed as source at runtime and returns with a top-level
# `return`, which is not module syntax; each is a two-line shim that imports
# the bytecode module behind it.
#
# A ucode that cannot emit a module with these flags (ucode 2026.01.16 has no
# `-cmodule`, wwand CLAUDE.md) does not fail the build: the source is
# installed instead, which works the same, only without the start-up gain.

cmake_minimum_required(VERSION 3.13)

project(wwand-esim-transfer NONE)

option(UCODE_PRECOMPILE "Precompile the ucode to bytecode" ON)
find_program(UCODE_COMPILER ucode DOC "ucode interpreter used as bytecode compiler")

set(SRC ${CMAKE_CURRENT_SOURCE_DIR})
set(OUT ${CMAKE_BINARY_DIR}/out)

set(BYTECODE_OK OFF)

if(UCODE_PRECOMPILE AND UCODE_COMPILER)
  # what the real compile relies on: -cmodule, a dynlink import, an export
  # list, and the syntax the tree uses (?. ?? ??=)
  set(_probe_src ${CMAKE_BINARY_DIR}/uc_probe.uc)
  set(_probe_out ${CMAKE_BINARY_DIR}/uc_probe.out)
  file(WRITE ${_probe_src}
    "'use strict';\n"
    "import * as fs from 'fs';\n"
    "function p(x) { let a = x?.b ?? 0; a ??= 1; return a + length(fs); }\n"
    "export { p };\n")
  execute_process(
    COMMAND ${UCODE_COMPILER} -s -cmodule,dynlink=fs -o ${_probe_out} ${_probe_src}
    RESULT_VARIABLE _probe_rc OUTPUT_QUIET ERROR_VARIABLE _probe_err)

  if(_probe_rc EQUAL 0 AND EXISTS ${_probe_out})
    set(BYTECODE_OK ON)
    message(STATUS "wwand-esim-transfer: bytecode precompile enabled (${UCODE_COMPILER})")
  else()
    message(WARNING "wwand-esim-transfer: '${UCODE_COMPILER}' cannot precompile bytecode "
      "(rc=${_probe_rc}: ${_probe_err}) — installing ucode SOURCE instead")
  endif()
elseif(UCODE_PRECOMPILE)
  message(WARNING "wwand-esim-transfer: no ucode compiler — installing ucode SOURCE instead")
endif()

# ES modules -> -cmodule (installed to /usr/share/ucode/wwand/esim_transfer/)
set(UC_MODULES
  esim_transfer/sha1.uc esim_transfer/aka.uc esim_transfer/ts43.uc
  esim_transfer/meta.uc esim_transfer/hints.uc esim_transfer/http.uc
  esim_transfer/plugin.uc esim_transfer/ctl.uc
)

# executable scripts (shebang) -> -c (installed to /usr/libexec/wwand/)
set(UC_PROGRAMS
  libexec/esim-transfer-card
)

# require()d entry points: source, see the header
set(UC_PLAIN
  plugins/esim_transfer.uc ctl/transfer.uc
)

# what the modules import from outside this package
set(UC_EXTERN fs uloop uci)

# --- list drift and the invariants --------------------------------------------

file(GLOB _on_disk RELATIVE ${SRC} ${SRC}/esim_transfer/*.uc ${SRC}/plugins/*.uc ${SRC}/ctl/*.uc ${SRC}/libexec/*)
set(_listed ${UC_MODULES} ${UC_PROGRAMS} ${UC_PLAIN})

foreach(f IN LISTS _on_disk)
  if(NOT f IN_LIST _listed)
    message(FATAL_ERROR "${f} is not listed in CMakeLists.txt (UC_MODULES/_PROGRAMS/_PLAIN)")
  endif()
endforeach()

foreach(f IN LISTS _listed)
  if(NOT EXISTS ${SRC}/${f})
    message(FATAL_ERROR "CMakeLists.txt lists ${f}, which does not exist")
  endif()

  file(READ ${SRC}/${f} _body)

  if(_body MATCHES "(import|from)[^\n]*['\"]\\.\\.?/")
    message(FATAL_ERROR "${f} uses a relative import — bytecode needs namespaced ones")
  endif()
endforeach()

foreach(f IN LISTS UC_MODULES)
  if(f MATCHES "-")
    message(FATAL_ERROR "${f}: '-' in a module path cannot be resolved at runtime")
  endif()
endforeach()

set(_dyn "")

foreach(e IN LISTS UC_EXTERN)
  list(APPEND _dyn "dynlink=${e}")
endforeach()

foreach(f IN LISTS UC_MODULES)
  string(REGEX REPLACE "\\.uc$" "" _n ${f})
  string(REPLACE "/" "." _n ${_n})
  list(APPEND _dyn "dynlink=wwand.${_n}")
endforeach()

string(REPLACE ";" "," _dynflags "${_dyn}")

# --- per-file rules -----------------------------------------------------------

set(_outputs "")

foreach(f IN LISTS UC_MODULES UC_PROGRAMS)
  get_filename_component(_dir ${OUT}/${f} DIRECTORY)

  if(BYTECODE_OK)
    if(f IN_LIST UC_MODULES)
      set(_cflag "-cmodule,${_dynflags}")
    else()
      set(_cflag "-c${_dynflags}")
    endif()

    add_custom_command(OUTPUT ${OUT}/${f}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
      COMMAND ${UCODE_COMPILER} -s ${_cflag} -o ${OUT}/${f} ${SRC}/${f}
      DEPENDS ${SRC}/${f}
      COMMENT "ucode bytecode: ${f}")
  else()
    add_custom_command(OUTPUT ${OUT}/${f}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
      COMMAND ${CMAKE_COMMAND} -E copy ${SRC}/${f} ${OUT}/${f}
      DEPENDS ${SRC}/${f})
  endif()

  list(APPEND _outputs ${OUT}/${f})
endforeach()

foreach(f IN LISTS UC_PLAIN)
  get_filename_component(_dir ${OUT}/${f} DIRECTORY)
  add_custom_command(OUTPUT ${OUT}/${f}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    COMMAND ${CMAKE_COMMAND} -E copy ${SRC}/${f} ${OUT}/${f}
    DEPENDS ${SRC}/${f})
  list(APPEND _outputs ${OUT}/${f})
endforeach()

add_custom_target(esim_transfer_ucode ALL DEPENDS ${_outputs})
