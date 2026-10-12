#include "archive.h"
#include "archive_entry.h"

// Clang's Swift importer cannot represent upstream macros that cast through
// __LA_MODE_T. These aliases keep the original ABI constants in one C boundary.
static const unsigned int LS_ARCHIVE_IFDIR = AE_IFDIR;
static const unsigned int LS_ARCHIVE_IFLNK = AE_IFLNK;
static const unsigned int LS_ARCHIVE_IFREG = AE_IFREG;
