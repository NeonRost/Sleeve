//
//  CDShim.h
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
//  macOS provides raw access to audio CDs through ioctls that
//  <IOKit/storage/IOCDMediaBSDClient.h> defines as _IOWR macros. Swift does
//  not import these macros — the compiler reports
//
//      macro 'DKIOCCDREAD' unavailable: structure not supported
//
//  because _IOWR folds the size of a C struct in at compile time. The same
//  stumbling block as the TAGLIB_COMPLEX_PROPERTY_PICTURE macro: resolve it
//  in C, hand it over as a constant.
//
//  The structs themselves (dk_cd_read_t and relatives), on the other hand,
//  Swift sees on its own — `import IOKit.storage` is enough for that.
//

#ifndef SLEEVE_CD_SHIM_H
#define SLEEVE_CD_SHIM_H

#include <IOKit/storage/IOCDMediaBSDClient.h>
#include <sys/ioctl.h>

static const unsigned long kSleeveIOCDRead      = DKIOCCDREAD;
static const unsigned long kSleeveIOCDReadTOC   = DKIOCCDREADTOC;
static const unsigned long kSleeveIOCDReadISRC  = DKIOCCDREADISRC;
static const unsigned long kSleeveIOCDReadMCN   = DKIOCCDREADMCN;
static const unsigned long kSleeveIOCDGetSpeed  = DKIOCCDGETSPEED;
static const unsigned long kSleeveIOCDSetSpeed  = DKIOCCDSETSPEED;

#endif /* SLEEVE_CD_SHIM_H */
