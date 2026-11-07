// The decoder half of the C API (include/halfrate.h).
#include <cstring>
#include <new>

#include "fec.h"
#include "frame.h"
#include "decoder.h"
#include "halfrate.h"

struct hr_decoder {
	halfrate::dec::Decoder decoder;
};

extern "C" {

hr_decoder* hr_decoder_new(void) { return new (std::nothrow) hr_decoder(); }

void hr_decoder_free(hr_decoder* d) { delete d; }

// 本仓库补的一个导出：DroidStar 的 C 接口没暴露 reset，但 Decoder::reset() 本身就是 public，
// 切通话时直接调它比 free + new 干净（不会因为分配失败把一个空指针留在对象里）。
void hr_decoder_reset(hr_decoder* d) {
	if (d) d->decoder.reset();
}

int hr_decoder_set(hr_decoder* d, const char* name, double value) {
	if (!d || !name) return -1;
	return d->decoder.set(name, value) ? 0 : -1;
}

int hr_decode(hr_decoder* d, const uint8_t* frame, int16_t* pcm) {
	if (!pcm) return -1;
	if (!d) {
		std::memset(pcm, 0, HR_SAMPLES * sizeof(int16_t));
		return -1;
	}
	if (!frame) {
		d->decoder.decode_erased(pcm);
		return HR_ERASURE;
	}
	uint8_t bits[HR_BITS];
	halfrate::core::bits_from_bytes(frame, bits);
	return static_cast<int>(d->decoder.decode_bits(bits, pcm));
}

int hr_decode_air_errors(hr_decoder* d, const uint8_t* air, int16_t* pcm, int* errors) {
	if (errors) *errors = 0;
	if (!d || !air) return hr_decode(d, nullptr, pcm);
	uint8_t frame[HR_FRAME_BYTES];
	halfrate::core::FecErrors fe;
	const int total = halfrate::core::fec_decode_frame(air, frame, &fe);
	if (errors) *errors = total;
	return hr_decode(d, frame, pcm);
}

int hr_decode_air(hr_decoder* d, const uint8_t* air, int16_t* pcm) {
	return hr_decode_air_errors(d, air, pcm, nullptr);
}

}  // extern "C"
