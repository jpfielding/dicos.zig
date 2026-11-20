// Draw-list image calls with an explicit ImTextureID.
//
// zgui's `addImage`/`addImageQuad` pass a 16-byte ImTextureRef from Zig to C
// functions declared with an 8-byte ImTextureID, so on arm64 and x86-64 the
// id arrives as the (null) texture-data pointer and every later argument is
// shifted. zoxel draws its slice texture through these instead.
#include "imgui.h"

extern "C" {

void zoxel_AddImage(ImDrawList* dl, ImU64 tex, const float* pmin, const float* pmax,
                    const float* uvmin, const float* uvmax, ImU32 col) {
    dl->AddImage((ImTextureID)tex, ImVec2(pmin[0], pmin[1]), ImVec2(pmax[0], pmax[1]),
                 ImVec2(uvmin[0], uvmin[1]), ImVec2(uvmax[0], uvmax[1]), col);
}

void zoxel_AddImageQuad(ImDrawList* dl, ImU64 tex, const float* p, const float* uv, ImU32 col) {
    dl->AddImageQuad((ImTextureID)tex, ImVec2(p[0], p[1]), ImVec2(p[2], p[3]), ImVec2(p[4], p[5]),
                     ImVec2(p[6], p[7]), ImVec2(uv[0], uv[1]), ImVec2(uv[2], uv[3]),
                     ImVec2(uv[4], uv[5]), ImVec2(uv[6], uv[7]), col);
}

}
