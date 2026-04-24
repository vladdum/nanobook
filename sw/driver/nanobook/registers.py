"""BAR0 register map constants for the Nanobook XDMA wrapper.

Offsets are frozen at the end of M1 — changes require a spec PR.
"""

ID_MAGIC    = 0x4E414E4F
VERSION_1_0 = 0x0001_0000

REG_ID          = 0x00
REG_VERSION     = 0x04
REG_CONTROL     = 0x10
REG_STATUS      = 0x14
REG_GIT_SHA_LO  = 0x20
REG_GIT_SHA_HI  = 0x24

CTRL_ENABLE     = 1 << 0
CTRL_RESET      = 1 << 1
CTRL_PAUSE      = 1 << 2

STATUS_HBM_READY    = 1 << 0
STATUS_ETH10G_READY = 1 << 1
STATUS_HBM_DONE     = 1 << 8
STATUS_HBM_ANY_ERROR = 1 << 9

CTRL_HBM_SMOKE_GO   = 1 << 4
