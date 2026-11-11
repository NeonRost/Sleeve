//
//  SleeveTagLibShim.h
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
//  The one thing the TagLib C binding cannot do: save an MP3 the way it
//  was found.
//
//  `taglib_file_save` calls `FileRef::save()`, which for MPEG files means
//  `save(AllTags, StripOthers, ID3v2::v4, Duplicate)`: every ID3v2.3 tag
//  comes back as 2.4, and an ID3v1 tag appears that was never there.
//  Measured on copies of the test files. Older players, Windows Explorer and
//  some car radios do not read 2.4 — so a tagger that only changed a title
//  must not change the version (spec §2.1.1).
//
//  The implementation is C++ (Sleeve/TagEngine/SleeveTagLibShim.cpp); the
//  header stays C so that Swift imports it like `tag_c.h`.
//

#ifndef SLEEVE_TAGLIB_SHIM_H
#define SLEEVE_TAGLIB_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/// Saves a file opened with `taglib_file_new`. MP3: the ID3v2 version on
/// disk is kept (2.3 stays 2.3, 2.4 stays 2.4, a new tag is 2.4), ID3v1 and
/// APE are written only if the file already had them, nothing is stripped
/// or duplicated. Every other format saves as `taglib_file_save` does.
/// Returns 1 on success, 0 on failure.
int sleeve_taglib_file_save(void *file);

/// The major version of the file's ID3v2 tag (3 or 4), 0 when it has none
/// or is no MP3. For tests.
int sleeve_taglib_id3v2_version(void *file);

/// 1 when the MP3 carries an ID3v1 tag. For tests.
int sleeve_taglib_has_id3v1(void *file);

/// Bits per sample of a lossless file (FLAC, WAV, AIFF, ALAC, APE,
/// WavPack); 0 where the format has none (MP3, AAC, Opus …). The C binding
/// does not expose it, and a conversion to WAV needs it to keep 24 bits.
int sleeve_taglib_bits_per_sample(void *file);

/// The exact length of a FLAC file in sample frames, 0 for other formats.
/// The C binding only gives whole seconds; burning needs the sector.
long long sleeve_taglib_flac_sample_frames(void *file);

#ifdef __cplusplus
}
#endif

#endif
