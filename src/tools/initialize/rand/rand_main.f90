#include "types.h"
#include "dns_const.h"
#include "dns_error.h"

#define C_FILE_LOC "INIRAND"

PROGRAM INIRAND

  USE DNS_CONSTANTS
  USE DNS_GLOBAL
  USE RAND_LOCAL
#ifdef USE_MPI
  USE DNS_MPI, ONLY : ims_pro
#endif

  IMPLICIT NONE

  ! -------------------------------------------------------------------
  TREAL, DIMENSION(:,:), ALLOCATABLE, SAVE, TARGET :: x,y,z
  TREAL, DIMENSION(:,:), ALLOCATABLE, SAVE         :: q, s, txc
  TREAL, DIMENSION(:),   ALLOCATABLE, SAVE         :: wrk1d,wrk2d,wrk3d

  TINTEGER iq, is, isize_wrk3d, ierr

  CHARACTER*64 str, line
  CHARACTER*32 inifile

  ! ###################################################################
  inifile = 'dns.ini'

  CALL DNS_INITIALIZE

  CALL DNS_READ_GLOBAL(inifile)
  CALL RAND_READ_LOCAL(inifile)
#ifdef USE_MPI
  CALL DNS_MPI_INITIALIZE
#endif

  ALLOCATE(wrk1d(isize_wrk1d*inb_wrk1d))
  ALLOCATE(wrk2d(isize_wrk2d*inb_wrk2d))
  isize_wrk3d = isize_txc_field

  inb_txc = 3

#include "dns_alloc_arrays.h"

#include "dns_read_grid.h"

  ! ###################################################################
  CALL IO_WRITE_ASCII(lfile,'Initializing random fiels.')

#ifdef USE_MPI
  seed = seed + ims_pro         ! seed for random generator
#endif
  seed = - ABS(seed)

  IF ( ifourier .EQ. 1 ) THEN
    CALL OPR_FOURIER_INITIALIZE(txc, wrk1d,wrk2d,wrk3d)
  ENDIF

  CALL OPR_CHECK(imax,jmax,kmax, q, txc, wrk2d,wrk3d)

  itime = 0; rtime = C_0_R

  DO iq = 1,inb_flow
    CALL RAND_FIELD( ucov(iq), q(1,iq), txc(1,1), txc(1,2), txc(1,3), wrk2d,wrk3d )
  ENDDO
  IF ( ipdf .EQ. 2 ) THEN ! Gaussian PDF
    CALL RAND_COVARIANCE(ucov, q(:,1),q(:,2),q(:,3))
  ENDIF
  CALL DNS_WRITE_FIELDS('flow.rand', i2, imax,jmax,kmax, inb_flow, isize_field, q, txc)

  DO is = 1,inb_scal
    CALL RAND_FIELD( ucov(is), s(1,is), txc(1,1), txc(1,2), txc(1,3), wrk2d,wrk3d )
  ENDDO
  CALL DNS_WRITE_FIELDS('scal.rand', i1, imax,jmax,kmax, inb_scal, isize_field, s, txc)

  CALL DNS_END(0)

  STOP
END PROGRAM INIRAND
