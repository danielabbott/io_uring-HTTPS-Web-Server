
#include <liburing.h>
#include <stdint.h>

void io_uring_cqe_seen__(uintptr_t ring_, uintptr_t cqe_) {
	struct io_uring * ring = (struct io_uring *)ring_;
	struct io_uring_cqe * cqe = (struct io_uring_cqe *)cqe_;
	io_uring_cqe_seen(ring, cqe);
}

int io_uring_wait_cqe__(uintptr_t ring_, uintptr_t cqe_ptr_) {
	struct io_uring * ring = (struct io_uring *)ring_;
	struct io_uring_cqe ** cqe_ptr = (struct io_uring_cqe **)cqe_ptr_;
	return io_uring_wait_cqe(ring, cqe_ptr);
}

void sqe_set_buf_group(uintptr_t sqe_, uint32_t group) {
	struct io_uring_sqe * sqe = (struct io_uring_sqe *)sqe_;
	sqe->buf_group = group;
}

void sqe_set_flags(uintptr_t sqe_, uint8_t flags) {
	struct io_uring_sqe * sqe = (struct io_uring_sqe *)sqe_;
	sqe->flags = flags;
}
