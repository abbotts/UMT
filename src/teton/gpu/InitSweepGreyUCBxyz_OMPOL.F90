#include "macros.h"
#include "omp_wrappers.h"
!***********************************************************************
!                        Last Update:  09/2018, PFN                    *
!                                                                      *
!   InitGreySweepUCBxyz - This routine calculates the transfer         *
!                         matrices used for the direct solve for the   *
!                         scalar corrections.                          *
!                                                                      *
!***********************************************************************

   subroutine InitGreySweepUCBxyz_GPU

   use, intrinsic :: iso_c_binding, only : c_int
   use cmake_defines_mod, only : omp_device_team_thread_limit
   use Options_mod
   use kind_mod
   use constant_mod
   use Size_mod
   use Geometry_mod
   use QuadratureList_mod
   use GreyAcceleration_mod
   use AngleSet_mod
   use ArrayChecks_mod

   implicit none

!  Local Variables

   type(AngleSet),   pointer :: ASet

   integer    :: zone
   integer    :: angle
   integer    :: angle0
   integer    :: aSetID
   integer    :: angGTA
   integer    :: n
   integer    :: numAngles
   integer    :: setID
   integer    :: i
   integer    :: cface
   integer    :: ifp

   integer    :: c
   integer    :: c0 
   integer    :: c1
   integer    :: cez 
   integer    :: nCorner 
   integer    :: nCFaces
   integer    :: zSetID
   integer    :: nAngleSets
   integer    :: nZoneSets
   integer    :: nGTASets

   real(adqt) :: aez
   real(adqt) :: sigv
   real(adqt) :: sigv2
   real(adqt) :: gnum
   real(adqt) :: gtau
   real(adqt) :: B0
   real(adqt) :: B1
   real(adqt) :: B2
   real(adqt) :: coef
   real(adqt) :: dInv
   real(adqt) :: quadwt
   real(adqt) :: afp
   real(adqt) :: Sigt
   real(adqt) :: SigtEZ

   real(adqt), parameter :: fouralpha=1.82_adqt

!  Dynamic

   integer,    allocatable :: angleList(:,:)
   real(adqt), allocatable :: omega(:,:)

!  Constants
   nZoneSets  =  getNumberOfZoneSets(Quad)
   nAngleSets =  getNumberOfAngleSets(Quad)
   nGTASets   =  getNumberOfGTASets(Quad)

!  All angles have the same weight

   ASet      => getAngleSetData(Quad, nAngleSets+1)
   quadwt    =  ASet% weight(1)

   numAngles = 0
   do setID=1,nGTASets 
     ASet      => getAngleSetData(Quad, nAngleSets+setID)
     numAngles =  numAngles + ASet% numAngles
   enddo

   allocate( angleList(2,numAngles) )
   allocate( omega(3,numAngles) )

   do setID=1,nGTASets
     ASet   => getAngleSetData(Quad, nAngleSets+setID)
     angle0 =  ASet% angle0
     n      =  ASet% numAngles

     do angle=1,n
       angleList(1,angle0+angle) = nAngleSets + setID
       angleList(2,angle0+angle) = angle
       omega(:,angle0+angle)     = ASet% omega(:,angle)
     enddo
   enddo

     TETON_CHECK_BOUNDS1(Quad%AngSetPtr, numAngles)
     TETON_CHECK_BOUNDS1(Geom%corner1, nZoneSets)
     TETON_CHECK_BOUNDS1(Geom%corner2, nZoneSets)


     TOMP(target data map(to: numAngles, angleList, omega, quadwt))

     TOMP(target teams distribute num_teams(nZoneSets) thread_limit(omp_device_team_thread_limit) default(none) &)
     TOMPC(shared(nZoneSets, numAngles, Geom, GTA, omega)&)
     TOMPC(private(angle))

     ZoneSetLoop1: do zSetID=1,nZoneSets

       do angle=1,numAngles

         ! NOTE - This does not support a collapse(2), as it is not a canonical loop form due to the lookup in inner loop bounds.
         !$omp  parallel do default(none)  &
         !$omp& shared(Geom, GTA, angle, omega, zSetID)
         do c=Geom% corner1(zSetID),Geom% corner2(zSetID)
           do cface=1,Geom% nCFacesArray(c)
             GTA% AfpNorm(cface,c,angle) = DOT_PRODUCT( omega(:,angle),Geom% A_fp(:,cface,c))
             GTA% AezNorm(cface,c,angle) = DOT_PRODUCT( omega(:,angle),Geom% A_ez(:,cface,c))
           enddo
         enddo

         !$omp end parallel do

       enddo

     enddo ZoneSetLoop1

     TOMP(end target teams distribute)

     TOMP(target teams distribute num_teams(nZoneSets) thread_limit(omp_device_team_thread_limit) default(none)&)
     TOMPC(shared(nZoneSets, numAngles, Geom, GTA)&)
     TOMPC(private(angle))

     ZoneSetLoop2: do zSetID=1,nZoneSets

       do angle=1,numAngles

         !$omp  parallel do default(none)  &
         !$omp& shared(Geom, GTA, angle, zSetID) 

         do c=Geom% corner1(zSetID),Geom% corner2(zSetID)
           GTA% ANormSum(c,angle) = zero
           do cface=1,Geom% nCFacesArray(c)
             GTA% ANormSum(c,angle) = GTA% ANormSum(c,angle) + half*   &
            (GTA% AfpNorm(cface,c,angle) + abs( GTA% AfpNorm(cface,c,angle) ) +  &
             GTA% AezNorm(cface,c,angle) + abs( GTA% AezNorm(cface,c,angle) ) )
           enddo
         enddo

         !$omp end parallel do

       enddo

     enddo ZoneSetLoop2

     TOMP(end target teams distribute)

     TOMP(target teams distribute num_teams(nZoneSets) thread_limit(omp_device_team_thread_limit) default(none)&)
     TOMPC(shared(nZoneSets, Geom, GTA, Quad, numAngles, angleList, quadwt) &)
     TOMPC(private(zone,ifp,c0,cez,nCorner,nCFaces,aSetID,angGTA) &)
     TOMPC(private(aez,afp,sigv,sigv2,gnum,gtau,B0,B1,B2,coef,dInv,Sigt,SigtEZ))

     ZoneSetLoop: do zSetID=1,nZoneSets

     !$omp  parallel do default(none)  &
     !$omp& shared(Geom, GTA, Quad, numAngles, angleList, quadwt, zSetID)  &
     !$omp& private(zone,ifp,c0,cez,nCorner,nCFaces,aSetID,angGTA) &
     !$omp& private(aez,afp,sigv,sigv2,gnum,gtau,B0,B1,B2,coef,dInv,Sigt,SigtEZ)

       ZoneLoop: do zone=Geom% zone1(zSetID),Geom% zone2(zSetID)

         nCorner = Geom% numCorner(zone)
         c0      = Geom% cOffSet(zone)

         do c1=1,nCorner
           do c=1,nCorner
             GTA% TT(c,c0+c1) = zero
           enddo
         enddo

         AngleLoop: do Angle=1,numAngles

           aSetID = angleList(1,Angle)
           angGTA = angleList(2,Angle)

           do c=1,nCorner
             do c1=1,nCorner
               GTA% Pvv(c1,c0+c) = zero
             enddo
             GTA% Pvv(c,c0+c) = Geom% Volume(c0+c)
           enddo

!          Loop over corners 

           CornerLoop: do c=1,nCorner

             Sigt     = GTA%GreySigTotal(c0+c)
             sigv     = Geom% Volume(c0+c)*Sigt 
             nCFaces  = Geom% nCFacesArray(c0+c)

!            Contributions from interior corner faces (EZ faces)

             do cface=1,nCfaces

               aez = GTA% AezNorm(cface,c0+c,angle) 
               cez = Geom% cEZ(cface,c0+c)

               if (aez > zero ) then

                 ifp    = mod(cface,nCFaces) + 1
                 afp    = GTA% AfpNorm(ifp,c0+c,angle)
                 SigtEZ = GTA%GreySigTotal(c0+cez)

                 TestOppositeFace: if (afp < zero) then

                   sigv2     = sigv*sigv

                   gnum      = aez*aez*( fouralpha*sigv2 +    &
                               aez*(four*sigv + three*aez) )

                   gtau      = gnum/    &
                             ( gnum + four*sigv2*sigv2 + aez*sigv*(six*sigv2 + &
                               two*aez*(two*sigv + aez)) )

                   B0        = half*aez*(one - gtau)
                   B1        = (B0 - gtau*sigv)/Sigt 
                   B2        =  B0/SigtEZ 

!                  Pvv(column,row)
                   GTA% Pvv(c,c0+c)     = GTA% Pvv(c,c0+c)     + B1
                   GTA% Pvv(cez,c0+c)   = GTA% Pvv(cez,c0+c)   - B2
                   GTA% Pvv(c,c0+cez)   = GTA% Pvv(c,c0+cez)   - B1
                   GTA% Pvv(cez,c0+cez) = GTA% Pvv(cez,c0+cez) + B2
          
                 else

                   B1           = half*aez/Sigt
                   B2           = half*aez/SigtEZ

!                  Pvv(column,row)
                   GTA% Pvv(c,c0+c)     = GTA% Pvv(c,c0+c)     + B1
                   GTA% Pvv(cez,c0+c)   = GTA% Pvv(cez,c0+c)   - B2
                   GTA% Pvv(c,c0+cez)   = GTA% Pvv(c,c0+cez)   - B1
                   GTA% Pvv(cez,c0+cez) = GTA% Pvv(cez,c0+cez) + B2
          
                 endif TestOppositeFace

               endif

             enddo

           enddo CornerLoop

           do i=1,nCorner

             c    = Quad% AngSetPtr(aSetID)% nextC(c0+i,angGTA) 

             dInv = one/(GTA% ANormSum(c0+c,angle) +   &
                         Geom% Volume(c0+c)*GTA%GreySigTotal(c0+c))

             do c1=1,nCorner
               GTA% Pvv(c1,c0+c) = dInv*GTA% Pvv(c1,c0+c)
             enddo

!            Calculate the contribution of this flux to the sources of
!            downstream corners in this zone. 

             nCFaces = Geom% nCFacesArray(c0+c)

             do cface=1,nCFaces
               aez = GTA% AezNorm(cface,c0+c,angle)

               if (aez > zero) then
                 cez = Geom% cEZ(cface,c0+c)

                 do c1=1,nCorner
                   GTA% Pvv(c1,c0+cez) = GTA% Pvv(c1,c0+cez) + aez*GTA% Pvv(c1,c0+c)
                 enddo
               endif
             enddo

           enddo
       
           do c=1,nCorner
             do c1=1,nCorner
               GTA% TT(c1,c0+c) = GTA% TT(c1,c0+c) + quadwt*GTA% Pvv(c1,c0+c)
             enddo
           enddo

         enddo AngleLoop

       enddo ZoneLoop

       !$omp end parallel do

     enddo ZoneSetLoop

     TOMP(end target teams distribute)
     TOMP(end target data)


   deallocate( angleList )
   deallocate( omega )

   return
   end subroutine InitGreySweepUCBxyz_GPU 


