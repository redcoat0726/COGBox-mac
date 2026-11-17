// The STB_IMAGE_WRITE implementation normally comes from frame_capture.cpp, whose body is Win32
// (DXGI desktop duplication). The PNG writer itself is portable, and buffer_dump.cpp needs
// stbi_write_png for its image dumps, so on other platforms the implementation is compiled here.
//
// Empty on Windows, where frame_capture.cpp provides it - two definitions in one link would
// collide.
#if !defined(_WIN32)
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>
#endif
