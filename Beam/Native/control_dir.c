/*
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
*/

#include <lean/lean.h>
#include <errno.h>
#include <stdint.h>
#include <sys/stat.h>

LEAN_EXPORT lean_obj_res lean_beam_lstat_mode(
    b_lean_obj_arg path,
    lean_obj_arg world) {
  (void)world;
#if defined(_WIN32)
  struct _stat status;
  if (_stat(lean_string_cstr(path), &status) != 0) {
#else
  struct stat status;
  if (lstat(lean_string_cstr(path), &status) != 0) {
#endif
    return lean_io_result_mk_error(lean_decode_io_error(errno, path));
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)(status.st_mode & 0777)));
}
