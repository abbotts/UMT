#include "macros.h"
#include "omp_wrappers.h"
!***********************************************************************
!                        Last Update:  01/2018, PFN                    *
!                                                                      *
!  SweepUCBxyz_GPU - This routine calculates angular fluxes for a      *
!                    single direction and multiple energy groups for   *
!                    for an upstream corner-balance (UCB) spatial      *
!                    in xyz-geometry.                                  *
!                                                                      *
!                    The work is offloaded to a GPU in which each      *
!                    computational "set" is a GPU block. The threads   *
!                    assigned to the block compute one group in one    *
!                    zone in a hyperplane (by definition, all of the   *
!                    zones in a hyperplane are independent).           *
!                                                                      *
!***********************************************************************

   subroutine SweepUCBxyz_GPU(nSets, sendIndex, savePsi)

   use, intrinsic :: iso_c_binding, only : c_int
   use cmake_defines_mod, only : omp_device_team_thread_limit
   use kind_mod
   use constant_mod
   use Size_mod
   use Geometry_mod
   use QuadratureList_mod
   use SetData_mod
   use AngleSet_mod
   use GroupSet_mod
   use ArrayChecks_mod

   implicit none

!  Arguments

   integer,          intent(in)    :: nSets
   integer,          intent(in)    :: sendIndex
   logical (kind=1), intent(in)    :: savePsi

!  Local

   type(SetData),    pointer       :: Set
   type(AngleSet),   pointer       :: ASet
   type(GroupSet),   pointer       :: GSet
   type(HypPlane),   pointer       :: HypPlanePtr
   type(BdyExit),    pointer       :: BdyExitPtr

   integer            :: setID
   integer            :: zSetID
   integer            :: Angle
   integer            :: g
   integer            :: Groups

   integer            :: mCycle
   integer            :: offSet
   integer            :: nAngleSets
   integer            :: nZoneSets

   integer            :: nzones
   integer            :: ii
   integer            :: ndoneZ
   integer            :: hyperPlane
   integer            :: nHyperplanes

   real(adqt)         :: tau

!  Local

   integer    :: b 
   integer    :: i 
   integer    :: cfp 
   integer    :: cface 
   integer    :: ifp
   integer    :: c
   integer    :: c0 
   integer    :: cez
   integer    :: nCFaces

   integer    :: zone
   integer    :: zone0
   integer    :: nCorner

   real(adqt), parameter :: fouralpha=1.82d0

   real(adqt) :: aez
   real(adqt) :: aez2
   real(adqt) :: area_opp

   real(adqt) :: source
   real(adqt) :: sig
   real(adqt) :: vol
   real(adqt) :: sigv
   real(adqt) :: sigv2
   real(adqt) :: gnum
   real(adqt) :: gden
   real(adqt) :: sez
   real(adqt) :: psi_opp
   real(adqt) :: afp
   real(adqt) :: denom

!  Dynamic

   integer, allocatable :: angleList(:)

!  Constants

   tau        = Size% tau
   nAngleSets = getNumberOfAngleSets(Quad)
   nZoneSets  = getNumberOfZoneSets(Quad)

   allocate( angleList(nAngleSets) )

   do setID=1,nSets
     Set => Quad% SetDataPtr(setID)
     angleList(Set% angleSetID) = Set% AngleOrder(sendIndex)
   enddo

!  Here the maximum block size is the product of the maximum
!  number of zones in a hyperplane and the number of groups;
!  The maximum value is the over all teams  

!  Note: num_blocks = nSets and the number of threads per 
!  team (a.k.a. "block") <= block_threads

!  Initialize

   ! Verify we won't get out-of-bounds accesses below.
   TETON_CHECK_BOUNDS1(Quad%AngSetPtr, nAngleSets)
   TETON_CHECK_BOUNDS1(Geom%corner1, nZoneSets)
   TETON_CHECK_BOUNDS1(Geom%corner2, nZoneSets)

   TOMP(target data map(to: tau, sendIndex, angleList))

   TOMP(target teams distribute num_teams(nZoneSets) thread_limit(omp_device_team_thread_limit) default(none) &)
   TOMPC(private(ASet, setID, Angle) &)
   TOMPC(shared(nZoneSets, angleList, Quad, Geom, nAngleSets) )

   !TOMP(target teams distribute num_teams(nZoneSets) thread_limit(omp_device_team_thread_limit) private(ASet, zSetID, setID, Angle))

   ZoneSetLoop: do zSetID=1,nZoneSets

!    Loop over angle sets

     do setID=1,nAngleSets

       ASet  => Quad% AngSetPtr(setID)
       angle =  angleList(setID)

! NOTE: This loop doesn't support a collapse(2), as its not a canonical form
! loop ( the inner loop bounds can not be predetermined ); it's significantly
! faster to split into two loops as below

!$omp  parallel do collapse(2) default(none) &
!$omp& shared(Geom, ASet, Angle, zSetID)
       do c=Geom% corner1(zSetID),Geom% corner2(zSetID)
         do cface=1,3
           ASet% AfpNorm(cface,c) = DOT_PRODUCT( ASet% omega(:,angle),Geom% A_fp(:,cface,c) )
           ASet% AezNorm(cface,c) = DOT_PRODUCT( ASet% omega(:,angle),Geom% A_ez(:,cface,c) )
         enddo
       enddo
!$omp end parallel do

!$omp  parallel do default(none)  &
!$omp& shared(Geom, ASet, Angle, zSetID)
       do c=Geom% corner1(zSetID),Geom% corner2(zSetID)
         do cface=4,Geom% nCFacesArray(c)
           ASet% AfpNorm(cface,c) = DOT_PRODUCT( ASet% omega(:,angle),Geom% A_fp(:,cface,c) )
           ASet% AezNorm(cface,c) = DOT_PRODUCT( ASet% omega(:,angle),Geom% A_ez(:,cface,c) )
         enddo
       enddo
!$omp end parallel do

     enddo

   enddo ZoneSetLoop

TOMP(end target teams distribute)

TOMP(target teams distribute num_teams(nZoneSets) thread_limit(omp_device_team_thread_limit) default(none) &)
TOMPC(private(ASet) &)
TOMPC(shared(nZoneSets, nAngleSets, Quad, Geom))

!!TOMP(target teams distribute num_teams(nZoneSets) thread_limit(omp_device_team_thread_limit) private(ASet, zSetID, setID))

   ZoneSetLoop2: do zSetID=1,nZoneSets

!    Loop over angle sets

     do setID=1,nAngleSets

       ASet  => Quad% AngSetPtr(setID)

!$omp  parallel do default(none)  &
!$omp& shared(Geom, ASet, zSetID)

       do c=Geom% corner1(zSetID),Geom% corner2(zSetID)
         ASet% ANormSum(c) = zero
         do cface=1,Geom% nCFacesArray(c)
           ASet% ANormSum(c) = ASet% ANormSum(c) + half*   &
                              (ASet% AfpNorm(cface,c) + abs( ASet% AfpNorm(cface,c) ) +  & 
                               ASet% AezNorm(cface,c) + abs( ASet% AezNorm(cface,c) ) )
         enddo
       enddo

!$omp end parallel do

     enddo

   enddo ZoneSetLoop2

TOMP(end target teams distribute)


TOMP(target teams distribute num_teams(nSets) thread_limit(omp_device_team_thread_limit) default(none) &)
TOMPC(shared(sendIndex, Quad, nSets) &)
TOMPC(private(Set, ASet, Angle, Groups, offSet))

!TOMP(target teams distribute num_teams(nSets) thread_limit(omp_device_team_thread_limit) private(Set, ASet, setID, Angle, Groups) &)
!TOMPC(private(mCycle, c, g, offSet))

   SetLoop0: do setID=1,nSets

     Set          => Quad% SetDataPtr(setID)
     ASet         => Quad% AngSetPtr(Set% angleSetID)

     Groups       =  Set% Groups
     Angle        =  Set% AngleOrder(sendIndex)
     offSet       =  ASet% cycleOffSet(angle)

!  Initialize boundary values in Psi1 and interior values on the cycle
!  list

!$omp  parallel do collapse(2) default(none) &
!$omp& shared(Angle, Set, ASet, offSet, Groups) private(c)
     do mCycle=1,ASet% numCycles(Angle)
       do g=1,Groups
         c              = ASet% cycleList(offSet+mCycle)
         Set% Psi1(g,c) = Set% cyclePsi(g,offSet+mCycle)
       enddo
     enddo
!$omp end parallel do


!$omp  parallel do collapse(2) default(none) &
!$omp& shared(Set, Groups, Angle)
     do c=1,Set%nbelem
       do g=1,Groups
         Set% Psi1(g,Set%nCorner+c) = Set% PsiB(g,c,Angle)
       enddo
     enddo
!$omp end parallel do

   enddo SetLoop0

TOMP(end target teams distribute)


! TODO:
! IBM XLF segfaults if 'hyperPlane' is not scoped to private below.
! This should not be necessary, as this is a loop control variables which the runtime should automatically scope to
! private.
!
! Relevant portions of OpenMP spec:
! `The loop iteration variable in any associated loop of a for, parallel for,
! taskloop, or distribute construct is private.`
!
! `A loop iteration variable for a sequential loop in a parallel or task
! generating construct is private in the innermost such construct that encloses
! the loop.`
! 
! Look into reporting this bug to IBM, using UMT as a reproducer.
TOMP(target teams distribute num_teams(nSets) thread_limit(omp_device_team_thread_limit) &)
TOMPC(private(Set, ASet, GSet, HypPlanePtr, Angle, Groups) &)
TOMPC(private(nHyperPlanes, ndoneZ, nzones, hyperPlane)) 

   SetLoop: do setID=1,nSets

     Set          => Quad% SetDataPtr(setID)
     ASet         => Quad% AngSetPtr(Set% angleSetID) 
     GSet         => Quad% GrpSetPtr(Set% groupSetID) 

     Groups       =  Set% Groups
     Angle        =  Set% AngleOrder(sendIndex)
     nHyperPlanes =  ASet% nHyperPlanes(Angle)
     ndoneZ       =  0
     HypPlanePtr  => ASet% HypPlanePtr(Angle)

     HyperPlaneLoop: do hyperPlane=1,nHyperPlanes

       nzones = HypPlanePtr% zonesInPlane(hyperPlane)

!$omp  parallel do collapse(2) default(none) &
!$omp& shared(Set, Geom, ASet, GSet, Angle, nzones, Groups) &
!$omp& shared(ndoneZ, tau) &
!$omp& private(c0,cfp,ifp,cez,zone,zone0,nCorner,nCFaces) &
!$omp& private(aez,aez2,area_opp,source,sig,vol) &
!$omp& private(sigv,sigv2,sez,gnum,gden,psi_opp) &
!$omp& private(afp,denom)

       ZoneLoop: do ii=1,nzones
         GroupLoop: do g=1,Groups

!          Loop through the zones using the NEXTZ list

           zone0   = ASet% nextZ(ndoneZ+ii,Angle)
           zone    = iabs( zone0 )
           nCorner = Geom% numCorner(zone)
           c0      = Geom% cOffSet(zone)

           psi_opp = zero
           sig     = GSet% Sigt(g,zone)

!          Contributions from volume terms 

           do c=1,nCorner
             source         = GSet% STotal(g,c0+c) + tau*Set% Psi(g,c0+c,Angle)
             Set% Q(g,c,ii) = source
             Set% S(g,c,ii) = Geom% Volume(c0+c)*source
           enddo

           CornerLoop: do c=1,nCorner

!            Calculate Area_CornerFace dot Omega to determine the
!            contributions from incident fluxes across external
!            corner faces (FP faces)

             nCFaces = Geom% nCFacesArray(c0+c)

             do cface=1,nCFaces

               afp = ASet% AfpNorm(cface,c0+c)
               cfp = Geom% cFP(cface,c0+c)

               if ( afp < zero ) then
                 Set% S(g,c,ii) = Set% S(g,c,ii) - afp*Set% Psi1(g,cfp)
               endif
             enddo

!            Contributions from interior corner faces (EZ faces)

             do cface=1,nCFaces

               aez = ASet% AezNorm(cface,c0+c) 
               cez = Geom% cEZ(cface,c0+c)

               if (aez > zero ) then

                 area_opp = zero

                 ifp = mod(cface,nCFaces) + 1
                 afp = ASet% AfpNorm(ifp,c0+c)

                 if ( afp < zero ) then
                   cfp      =  Geom% cFP(ifp,c0+c)
                   area_opp = -afp
                   psi_opp  = -afp*Set% Psi1(g,cfp)
                 endif

                 do i=2,nCFaces-2
                   ifp = mod(ifp,nCFaces) + 1
                   afp = ASet% AfpNorm(ifp,c0+c)
                   if ( afp < zero ) then
                     cfp      = Geom% cFP(ifp,c0+c)
                     area_opp = area_opp - afp
                     psi_opp  = psi_opp  - afp*Set% Psi1(g,cfp)
                   endif
                 enddo

                 TestOppositeFace: if ( area_opp > zero ) then

                   psi_opp  = psi_opp/area_opp
 
                   aez2     = aez*aez
                   vol      = Geom% Volume(c0+c)
 
                   sigv     = sig*vol
                   sigv2    = sigv*sigv

                   gnum     = aez2*( fouralpha*sigv2 +              &
                              aez*(four*sigv + three*aez) )

                   gden     = vol*( four*sigv*sigv2 + aez*(six*sigv2 + &
                              two*aez*(two*sigv + aez)) )

                   sez      = ( vol*gnum*( sig*psi_opp - Set% Q(g,c,ii) ) +   &
                                half*aez*gden*( Set% Q(g,c,ii) - Set% Q(g,cez,ii) ) )/ &
                              ( gnum + gden*sig)

                   Set% S(g,c,ii)   = Set% S(g,c,ii)   + sez
                   Set% S(g,cez,ii) = Set% S(g,cez,ii) - sez

                 else

                   sez              = half*aez*( Set% Q(g,c,ii) - Set% Q(g,cez,ii) )/sig
                   Set% S(g,c,ii)   = Set% S(g,c,ii)   + sez
                   Set% S(g,cez,ii) = Set% S(g,cez,ii) - sez

                 endif TestOppositeFace

               endif

             enddo

           enddo CornerLoop


           if ( zone0 > 0 ) then

             do i=1,nCorner

               c = ASet% nextC(c0+i,angle) 

!              Corner angular flux
               denom             = ASet% ANormSum(c0+c) + sig*Geom% Volume(c0+c)
               Set% Psi1(g,c0+c) = Set% S(g,c,ii)/denom

!              Calculate the contribution of this flux to the sources of
!              downstream corners in this zone. The downstream corner index is
!              "ez_exit."

               nCFaces = Geom% nCFacesArray(c0+c)

               do cface=1,nCFaces
                 aez = ASet% AezNorm(cface,c0+c)

                 if (aez > zero) then
                   cez              = Geom% cEZ(cface,c0+c) 
                   Set% S(g,cez,ii) = Set% S(g,cez,ii) + aez*Set% Psi1(g,c0+c)
                 endif
               enddo

             enddo

           else

!          Direct Solve (non-lower triangular, use old values of Psi1)
             do c=1,nCorner
               do cface=1,Geom% nCFacesArray(c0+c)
                 aez = ASet% AezNorm(cface,c0+c)

                 if (aez > zero) then
                   cez              = Geom% cEZ(cface,c0+c)
                   Set% S(g,cez,ii) = Set% S(g,cez,ii) + aez*Set% Psi1(g,c0+c)
                 endif
               enddo
             enddo

             do c=1,nCorner
               Set% Psi1(g,c0+c) = Set% S(g,c,ii)/(ASet% ANormSum(c0+c) + sig*Geom% Volume(c0+c))
             enddo

           endif

         enddo GroupLoop
       enddo ZoneLoop

!$omp end parallel do

       ndoneZ = ndoneZ + nzones

     enddo HyperPlaneLoop

   enddo SetLoop

TOMP(end target teams distribute)

!  Update Boundary data

TOMP(target teams distribute num_teams(nSets) thread_limit(omp_device_team_thread_limit) default(none) &)
TOMPC(shared(nSets, Quad, sendIndex)&)
TOMPC(private(Set, ASet, BdyExitPtr, offSet, Angle, Groups, b, c))

     SetLoop3: do setID=1,nSets

       Set        => Quad% SetDataPtr(setID)
       ASet       => Quad% AngSetPtr(Set% angleSetID)
       Groups     =  Set% Groups
       Angle      =  Set% AngleOrder(sendIndex)
       offSet     =  ASet% cycleOffSet(angle)
       BdyExitPtr => ASet% BdyExitPtr(Angle)

!$omp  parallel do collapse(2) default(none) &
!$omp& shared(Set, BdyExitPtr, Groups, Angle) private(b,c)

       do i=1,BdyExitPtr% nxBdy
         do g=1,Groups
           b = BdyExitPtr% bdyList(1,i)
           c = BdyExitPtr% bdyList(2,i)

           Set% PsiB(g,b,Angle) = Set% Psi1(g,c)
         enddo
       enddo

!$omp end parallel do

!      Update Psi in the cycle list

!$omp  parallel do collapse(2) default(none) &
!$omp& shared(Angle, Set, ASet, offSet, Groups) private(c)
       do mCycle=1,ASet% numCycles(angle)
         do g=1,Groups
           c                              = ASet% cycleList(offSet+mCycle)
           Set% cyclePsi(g,offSet+mCycle) = Set% Psi1(g,c)
         enddo
       enddo
!$omp end parallel do

     enddo SetLoop3

TOMP(end target teams distribute)

!  We only store Psi if this is the last transport sweep in the time step

   if ( savePsi ) then

TOMP(target teams distribute num_teams(nSets) thread_limit(omp_device_team_thread_limit) default(none)&)
TOMPC(shared(nSets, Quad, sendIndex)&)
TOMP(private(Set, Angle, Groups))

     SetLoop2: do setID=1,nSets

       Set    => Quad% SetDataPtr(setID)
       Groups =  Set% Groups
       Angle  =  Set% AngleOrder(sendIndex)

!$omp  parallel do collapse(2) default(none) &
!$omp& shared(Set, ASet, Angle, Groups)

       CornerLoop2: do c=1,Set% nCorner
         GroupLoop2: do g=1,Groups

           Set% Psi(g,c,Angle) = Set% Psi1(g,c)

         enddo GroupLoop2
       enddo CornerLoop2

!$omp end parallel do

     enddo SetLoop2

TOMP(end target teams distribute)

   endif

TOMP(end target data)

   deallocate( angleList )

   return
   end subroutine SweepUCBxyz_GPU


!***********************************************************************
!                        Last Update:  01/2018, PFN                    *
!                                                                      *
!   SweepUCBxyz_kernel - This routine calculates angular fluxes for a  *
!                        single direction, energy group and zone for   *
!                        for an upstream corner-balance (UCB) spatial  *
!                        in xyz-geometry.                              *
!                                                                      *
!***********************************************************************

