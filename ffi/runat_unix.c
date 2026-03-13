/*
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
*/

#include <lean/lean.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static lean_obj_res mk_io_error_from_errno(char const *op, char const *path) {
  char msg[512];
  if (path && path[0] != '\0') {
    snprintf(msg, sizeof(msg), "%s failed for %s: %s", op, path, strerror(errno));
  } else {
    snprintf(msg, sizeof(msg), "%s failed: %s", op, strerror(errno));
  }
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

static int read_exact(int fd, char *buf, size_t n) {
  size_t off = 0;
  while (off < n) {
    ssize_t got = read(fd, buf + off, n - off);
    if (got == 0) return 0;
    if (got < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    off += (size_t)got;
  }
  return 1;
}

static int write_exact(int fd, char const *buf, size_t n) {
  size_t off = 0;
  while (off < n) {
    ssize_t sent = write(fd, buf + off, n - off);
    if (sent < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    off += (size_t)sent;
  }
  return 0;
}

LEAN_EXPORT lean_obj_res lean_runat_unix_listen(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
  char const *path_c = lean_string_cstr(path);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return mk_io_error_from_errno("socket", path_c);
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (strlen(path_c) >= sizeof(addr.sun_path)) {
    close(fd);
    return lean_io_result_mk_error(
        lean_mk_io_user_error(lean_mk_string("unix socket path is too long")));
  }
  strncpy(addr.sun_path, path_c, sizeof(addr.sun_path) - 1);
  unlink(path_c);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return mk_io_error_from_errno("bind", path_c);
  }
  if (listen(fd, 16) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return mk_io_error_from_errno("listen", path_c);
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}

LEAN_EXPORT lean_obj_res lean_runat_unix_accept(b_lean_obj_arg fd_obj, lean_obj_arg world) {
  (void)world;
  uint32_t fd_u32 = lean_unbox_uint32(fd_obj);
  int fd = (int)fd_u32;
  int client = -1;
  do {
    client = accept(fd, NULL, NULL);
  } while (client < 0 && errno == EINTR);
  if (client < 0) return mk_io_error_from_errno("accept", NULL);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)client));
}

LEAN_EXPORT lean_obj_res lean_runat_unix_connect(b_lean_obj_arg path, lean_obj_arg world) {
  (void)world;
  char const *path_c = lean_string_cstr(path);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return mk_io_error_from_errno("socket", path_c);
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (strlen(path_c) >= sizeof(addr.sun_path)) {
    close(fd);
    return lean_io_result_mk_error(
        lean_mk_io_user_error(lean_mk_string("unix socket path is too long")));
  }
  strncpy(addr.sun_path, path_c, sizeof(addr.sun_path) - 1);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return mk_io_error_from_errno("connect", path_c);
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}

LEAN_EXPORT lean_obj_res lean_runat_unix_close(b_lean_obj_arg fd_obj, lean_obj_arg world) {
  (void)world;
  uint32_t fd_u32 = lean_unbox_uint32(fd_obj);
  int fd = (int)fd_u32;
  if (close(fd) < 0 && errno != EBADF) return mk_io_error_from_errno("close", NULL);
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_runat_unix_send_msg(b_lean_obj_arg fd_obj, b_lean_obj_arg msg,
                                                  lean_obj_arg world) {
  (void)world;
  uint32_t fd_u32 = lean_unbox_uint32(fd_obj);
  int fd = (int)fd_u32;
  char const *payload = lean_string_cstr(msg);
  size_t payload_len = lean_string_size(msg) - 1;
  char header[64];
  int hdr_len = snprintf(header, sizeof(header), "%zu\n", payload_len);
  if (hdr_len <= 0 || (size_t)hdr_len >= sizeof(header)) {
    return lean_io_result_mk_error(
        lean_mk_io_user_error(lean_mk_string("failed to encode broker header")));
  }
  if (write_exact(fd, header, (size_t)hdr_len) < 0) return mk_io_error_from_errno("write", NULL);
  if (payload_len > 0 && write_exact(fd, payload, payload_len) < 0)
    return mk_io_error_from_errno("write", NULL);
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_runat_unix_recv_msg(b_lean_obj_arg fd_obj, lean_obj_arg world) {
  (void)world;
  uint32_t fd_u32 = lean_unbox_uint32(fd_obj);
  int fd = (int)fd_u32;
  char header[64];
  size_t h = 0;
  while (h + 1 < sizeof(header)) {
    char c = 0;
    int r = read_exact(fd, &c, 1);
    if (r == 0) {
      return lean_io_result_mk_error(
          lean_mk_io_user_error(lean_mk_string("broker connection closed")));
    }
    if (r < 0) return mk_io_error_from_errno("read", NULL);
    if (c == '\n') break;
    header[h++] = c;
  }
  if (h + 1 >= sizeof(header)) {
    return lean_io_result_mk_error(
        lean_mk_io_user_error(lean_mk_string("invalid broker header")));
  }
  header[h] = '\0';
  char *end = NULL;
  errno = 0;
  unsigned long long len64 = strtoull(header, &end, 10);
  if (errno != 0 || end == header || *end != '\0') {
    return lean_io_result_mk_error(
        lean_mk_io_user_error(lean_mk_string("invalid broker length")));
  }
  size_t len = (size_t)len64;
  char *buf = NULL;
  if (len > 0) {
    buf = (char *)malloc(len);
    if (!buf) {
      return lean_io_result_mk_error(
          lean_mk_io_user_error(lean_mk_string("out of memory reading broker message")));
    }
    int r = read_exact(fd, buf, len);
    if (r == 0) {
      free(buf);
      return lean_io_result_mk_error(
          lean_mk_io_user_error(lean_mk_string("broker connection closed")));
    }
    if (r < 0) {
      int saved = errno;
      free(buf);
      errno = saved;
      return mk_io_error_from_errno("read", NULL);
    }
  }
  lean_obj_res msg = lean_mk_string_from_bytes(buf ? buf : "", len);
  if (buf) free(buf);
  return lean_io_result_mk_ok(msg);
}

