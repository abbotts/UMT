#include "macros.h"
!=======================================================================
! Functions for getting/setting runtime options
!=======================================================================
 
module Options_mod 
  use Datastore_mod, only : theDatastore
  use, intrinsic :: iso_fortran_env, only: int32 
  use, intrinsic :: iso_c_binding, only : c_bool, c_int
  implicit none

  private

  type :: options_type
  contains
    procedure :: getNumOmpMaxThreads
    procedure :: getMPIUseDeviceAddresses
    procedure :: initialize
    procedure :: check
    procedure :: getVerbose
    procedure :: isRankVerbose
    procedure :: isRankZeroVerbose
    procedure :: setVerbose
  end type options_type

  public :: setVerboseOldCVersion

  type(options_type), public :: Options

contains

!=======================================================================
! Populate options with default values.
! TODO - Move any appropriate defaults to
! Radar C++ API( for general TRT options )
! instead of here in the Fortran.
!=======================================================================
  subroutine initialize(self)
#if defined(TETON_ENABLE_OPENMP)
    use omp_lib
#endif
    use cmake_defines_mod

    class(options_type) :: self

    logical*4 :: temp
    integer :: omp_cpu_max_threads

    ! Default to current max number of threads value set in OpenMP runtime.
#if defined(TETON_ENABLE_OPENMP)
       omp_cpu_max_threads = omp_get_max_threads()
#else
       omp_cpu_max_threads = 1
#endif
    call theDatastore%root%set_path("options/concurrency/omp_cpu_max_threads", omp_cpu_max_threads)

    ! Default to not using device (GPU) addresses for MPI
    call theDatastore%root%set_path("options/mpi/useDeviceAddresses", 0)

    ! Build information.
    ! These are populated in the cmake_defines_mod.F90
    call theDatastore%root%set_path("build_meta_data/cmake_install_prefix",install_prefix)
    call theDatastore%root%set_path("build_meta_data/project_version", version)
    call theDatastore%root%set_path("build_meta_data/git_sha1", git_sha1)
    call theDatastore%root%set_path("build_meta_data/cmake_system", system_type)
    call theDatastore%root%set_path("build_meta_data/cmake_cxx_compiler", cxx_compiler)
    call theDatastore%root%set_path("build_meta_data/cmake_fortran_compiler", fortran_compiler)

    ! Default to not verbose
    temp = theDatastore%root%has_path("options/verbose")
    if (.NOT. temp) then
      call theDatastore%root%set_path("options/verbose", 0)
    endif
      
    call self%check()
  end subroutine

!=======================================================================
! Validate the option values.
! TODO - Implement this in
! Radar C++ API( for general TRT options )
!
! Leave in Fortran until then, so we can catch any input errors early.
! Also need some assert macros in the C++...
!=======================================================================
  subroutine check(self)
    class(options_type) :: self
    logical*4 :: temp

    ! Retrieve value in local 4 byte logical to workaround buffer overflow in
    ! conduit API.  Will be fixed in future conduit version.
    temp = theDatastore%root%has_path("options/concurrency")
    TETON_VERIFY(temp, "Options tree is missing 'concurrency'.")
    temp = theDatastore%root%has_path("options/concurrency/omp_cpu_max_threads")
    TETON_VERIFY(temp, "Options is missing concurrency/omp_cpu_max_threads.")

    temp = theDatastore%root%has_path("options/mpi/useDeviceAddresses")
    TETON_VERIFY(temp, "Options tree is missing mpi/useDeviceAddresses.")

    temp = theDatastore%root%has_path("options/verbose")
    TETON_VERIFY(temp, "Options tree is missing verbose.")

  end subroutine
!=======================================================================
! Accessor functions for getting options.
!=======================================================================
  integer(kind=int32) function getNumOmpMaxThreads(self) result(numOmpMaxThreads)
    class(options_type) :: self
    numOmpMaxThreads = theDatastore%root%fetch_path_as_int32("options/concurrency/omp_cpu_max_threads")
  end function

  logical(kind=c_bool) function getMPIUseDeviceAddresses(self) result(useDeviceAddresses)
    class(options_type) :: self
    integer(kind=int32) :: useDeviceAddressesInt
    useDeviceAddressesInt = theDataStore%root%fetch_path_as_int32("options/mpi/useDeviceAddresses")

    if (useDeviceAddressesInt == 0) then
      useDeviceAddresses = .FALSE.
    else
      useDeviceAddresses = .TRUE.
    endif

  end function

!***********************************************************************
!    getVerbose - Get verbosity level.                                
!
!    verbose=x0 - no verbose output
!    verbose=0x - rank 0 at verbose level x
!    verbose=1x - all ranks at verbose level x
!***********************************************************************
   integer(kind=int32) function getVerbose(self) result(level)
      class(options_type) :: self
      level = theDatastore%root%fetch_path_as_int32("options/verbose")
   end function getVerbose

!***********************************************************************


!***********************************************************************
!    isRankVerbose - returns the local verbosity level of this rank
!***********************************************************************
   integer function isRankVerbose(self) result(verbose)
      use mpi

      class(options_type) :: self
      integer :: verbose_level
      integer :: rank, ierr

      call MPI_Comm_rank(MPI_COMM_WORLD,rank,ierr)
      verbose_level = self%getVerbose()

      ! verbose_level is a two digit number.
      ! The first digit determines whether only rank 0 is verbose
      ! The second digit determines the verbosity level.
      if (rank == 0 .OR. verbose_level > 10) then
         verbose = mod(verbose_level,10)
      else
         verbose = 0
      endif

      return

   end function isRankVerbose

!***********************************************************************
!    isRankZeroVerbose - returns the verbosity level of rank 0
!      This is useful for cases where all ranks need to do something
!      because of rank 0 being verbose.
!***********************************************************************
   integer function isRankZeroVerbose(self) result(verbose)
      use mpi
      class(options_type) :: self

      integer :: verbose_level

      verbose_level = self%getVerbose()
      verbose = mod(verbose_level,10)

      return

   end function isRankZeroVerbose

!***********************************************************************
!    setVerbose - Set verbosity level.
!    
!    verbose=x0 - no verbose output
!    verbose=0x - rank 0 at verbose level x
!    verbose=1x - all ranks at verbose level x
!***********************************************************************
   subroutine setVerbose(self, level)
      class(options_type) :: self
      integer(kind=C_INT), intent(in) :: level
      integer :: rank, ierr

      ! TODO - Remove this when we have a proper teton initialize() function
      call theDatastore%initialize()

      call theDatastore%root%set_path("options/verbose", level)

      if ( self%isRankVerbose() > 0 ) then
         print *, "Teton: verbose output enabled."
      endif

      return
   end subroutine setVerbose

!***********************************************************************
!    setVerbose - Set verbosity level.  Old version that doesn't use   *
!    type bound procedure.                                             *
!***********************************************************************
   subroutine setVerboseOldCVersion(level) BIND(C,NAME="teton_setverbose")
      integer(kind=C_INT), intent(in) :: level

      ! TODO - Remove this when we have a proper teton initialize() function
      call theDatastore%initialize()

      call Options%setVerbose(level)

      return
   end subroutine setVerboseOldCVersion

end module Options_mod
