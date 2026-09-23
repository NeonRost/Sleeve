//
//  CDShim.h
//  Sleeve
//
//  macOS stellt den Rohzugriff auf Audio-CDs über ioctls bereit, die in
//  <IOKit/storage/IOCDMediaBSDClient.h> als _IOWR-Makros definiert sind.
//  Swift importiert diese Makros nicht — der Compiler meldet
//
//      macro 'DKIOCCDREAD' unavailable: structure not supported
//
//  weil _IOWR die Größe eines C-Structs zur Übersetzungszeit einrechnet.
//  Dieselbe Stolperstelle wie beim TAGLIB_COMPLEX_PROPERTY_PICTURE-Makro:
//  in C auflösen, als Konstante herüberreichen.
//
//  Die Structs selbst (dk_cd_read_t und Verwandte) sieht Swift dagegen
//  von sich aus — dafür genügt `import IOKit.storage`.
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
