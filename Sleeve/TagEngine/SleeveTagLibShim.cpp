//
//  SleeveTagLibShim.cpp
//  Sleeve
//
//  Copyright (C) 2026 NeonRost
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//  See Vendor/taglibshim/SleeveTagLibShim.h.
//

#include "../../Vendor/taglibshim/SleeveTagLibShim.h"

#include "../../Vendor/taglib/include/taglib/fileref.h"
#include "../../Vendor/taglib/include/taglib/mpegfile.h"
#include "../../Vendor/taglib/include/taglib/id3v2tag.h"
#include "../../Vendor/taglib/include/taglib/id3v2header.h"
#include "../../Vendor/taglib/include/taglib/flacproperties.h"
#include "../../Vendor/taglib/include/taglib/wavproperties.h"
#include "../../Vendor/taglib/include/taglib/aiffproperties.h"
#include "../../Vendor/taglib/include/taglib/mp4properties.h"
#include "../../Vendor/taglib/include/taglib/apeproperties.h"
#include "../../Vendor/taglib/include/taglib/wavpackproperties.h"

using namespace TagLib;

namespace {

MPEG::File *mpegFile(void *handle) {
    auto *ref = reinterpret_cast<FileRef *>(handle);
    if (!ref || ref->isNull()) return nullptr;
    return dynamic_cast<MPEG::File *>(ref->file());
}

}

extern "C" int sleeve_taglib_file_save(void *handle) {
    auto *ref = reinterpret_cast<FileRef *>(handle);
    if (!ref || ref->isNull()) return 0;

    MPEG::File *mpeg = mpegFile(handle);
    if (!mpeg) return ref->save() ? 1 : 0;

    int tags = MPEG::File::ID3v2;
    if (mpeg->hasID3v1Tag()) tags |= MPEG::File::ID3v1;
    if (mpeg->hasAPETag()) tags |= MPEG::File::APE;

    ID3v2::Version version = ID3v2::v4;
    if (mpeg->hasID3v2Tag() && mpeg->ID3v2Tag()->header()->majorVersion() == 3) {
        version = ID3v2::v3;
    }
    return mpeg->save(tags, File::StripNone, version, File::DoNotDuplicate) ? 1 : 0;
}

extern "C" int sleeve_taglib_id3v2_version(void *handle) {
    MPEG::File *mpeg = mpegFile(handle);
    if (!mpeg || !mpeg->hasID3v2Tag()) return 0;
    return static_cast<int>(mpeg->ID3v2Tag()->header()->majorVersion());
}

extern "C" int sleeve_taglib_bits_per_sample(void *handle) {
    auto *ref = reinterpret_cast<FileRef *>(handle);
    if (!ref || ref->isNull() || !ref->audioProperties()) return 0;
    const AudioProperties *p = ref->audioProperties();
    if (auto *x = dynamic_cast<const FLAC::Properties *>(p)) return x->bitsPerSample();
    if (auto *x = dynamic_cast<const RIFF::WAV::Properties *>(p)) return x->bitsPerSample();
    if (auto *x = dynamic_cast<const RIFF::AIFF::Properties *>(p)) return x->bitsPerSample();
    if (auto *x = dynamic_cast<const MP4::Properties *>(p)) return x->bitsPerSample();
    if (auto *x = dynamic_cast<const APE::Properties *>(p)) return x->bitsPerSample();
    if (auto *x = dynamic_cast<const WavPack::Properties *>(p)) return x->bitsPerSample();
    return 0;
}

extern "C" long long sleeve_taglib_flac_sample_frames(void *handle) {
    auto *ref = reinterpret_cast<FileRef *>(handle);
    if (!ref || ref->isNull() || !ref->audioProperties()) return 0;
    if (auto *x = dynamic_cast<const FLAC::Properties *>(ref->audioProperties())) {
        return static_cast<long long>(x->sampleFrames());
    }
    return 0;
}

extern "C" int sleeve_taglib_has_id3v1(void *handle) {
    MPEG::File *mpeg = mpegFile(handle);
    return (mpeg && mpeg->hasID3v1Tag()) ? 1 : 0;
}
