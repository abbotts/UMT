
#ifndef BLUEPRINT_HPP__
#define BLUEPRINT_HPP__

#include "conduit/conduit.hpp"
#include "conduit/conduit_blueprint.hpp"
#include "conduit/conduit_relay.hpp"
#include "TetonConduitInterface.hh"
#include <map>
#include <vector>
#include <set>
#include <algorithm> // for sort

/* ------------------------------------------------------------------------------------------------------------------ 
 * This class has a very large number of methods called.  Documenting the call chain here.
 *
 * Call chain:
 * - TetonBlueprint( blueprint node, parameters node )
 * - OutputTetonMesh( rank, communicator )
 *   - verifyInput(mMeshNode, comm);
 *   - CreateConnectivityArrays(mMeshNode, comm);
 *   - CreateConduitFaceAttributes(mMeshNode, rank);
 *   - ComputeFaceIDs( boundaries, nbelem_corner_faces, boundaries_types, boundary_conditions, m_face_to_bcid, rank);
 *   - ComputeTetonMeshConnectivityArray(rank);
 *     (several more methods called here, see comments below on ComputeTetonMeshConnectivityArray)
 *   - CreateTetonMeshCornerCoords();
 *   - verifyInput(mMeshNode, comm); // again, to verify corner mesh
 * - ~TetonBlueprint()
   ------------------------------------------------------------------------------------------------------------------ */


class TetonBlueprint
{
private:
   conduit::Node &mMeshNode;
   conduit::Node &mParametersNode;

/* ------------------------------------------------------------------------------------------------------------------ 
   This generates the blueprint face and corner topologies.  It also populates the following connectivity arrays
   later used by ComputeTetonMeshConnectivityArray:
   - zones to corners (two different arrays)
   - zones to faces, and faces to zones
   - faces to corners
   - array of the corner vertices
   ------------------------------------------------------------------------------------------------------------------ */
   void CreateConnectivityArrays(conduit::Node &conduit_blueprint_node, MPI_Comm comm);

/* ------------------------------------------------------------------------------------------------------------------ 
   This expands the boundary_attribute field (which is over just the boundary topology) to a new face_attribute field
   over all the mesh faces (specifically, the main_face topology).
   ------------------------------------------------------------------------------------------------------------------ */
   void CreateConduitFaceAttributes(conduit::Node &conduit_blueprint_node, int rank);

/* ------------------------------------------------------------------------------------------------------------------ 
   This builds several arrays containing the boundary condition information for each face.
   The non-shared boundary info is pulled from the face_attribute field generated by
   CreateConduitFaceAttributes.  The 'shared' boundary info is pulled from the blueprint face topology adjacency sets.
   ------------------------------------------------------------------------------------------------------------------ */
   void ComputeFaceIDs(std::map<int, std::vector<int>> &boundaries,
                       int &nbelem_corner_faces,
                       std::vector<int> &boundaries_types,
                       std::vector<int> &boundary_conditions,
                       std::vector<int> &face_to_bcid,
                       int rank);

/* ------------------------------------------------------------------------------------------------------------------ 
   Set of methods used to create the teton mesh connectivity array.  This array consists of, for each zone,:
     zoneID, - id of zone
     corner_offset, - offset of first corner in main corner array
     nzone_faces, - # faces in each zone
     ncorner_faces_total, - # # corner faces in each zone 
     nzone_corners, - # corners in zone
     zones_opp[] - for each zone face, the opposite zone across that face (-1 is boundary)
     corners_local[] - for each zone face, list of corner id ( local id ).  Ordering of corners follows left hand rule,
                       with thumb pointing out of zone. 
     corners_opp[] - id of opposite corner face for each corner face (global id)
     ncorners_on_zone_face[] - number of corners per zone face
     zone_faces_to_bcids[] - boundary condition id per zone face

   This array is passed to the Teton teton_setzone() subroutine.

   Call chain for these methods is:

   ComputeTetonMeshConnectivityArrays(rank);
   - ComputeLocalCornersInZone(nzones, ncorners);
   - ComputeCornerOffsets(nzones);
   - ComputeZoneFaceToHalfFaceDict();
   - ComputeSharedFaces(rank);
   - ComputeConnectivityArrays(zone, corner_offset, nzone_faces, ncorner_faces_total, nzone_corners, zones_opp,
                               corners_local, corners_opp, ncorners_on_zone_face, zone_faces_to_bcids, rank);
     - GetOppositeZone(zone, face);
     - GetOppositeCorner(zone, face, corner, rank);

   ------------------------------------------------------------------------------------------------------------------ */
   void ComputeTetonMeshConnectivityArray(int rank);
   void ComputeConnectivityArrays(int zone,
                                  int &corner_offset,
                                  int &nzone_faces,
                                  int &ncorner_faces,
                                  int &ncorners,
                                  std::vector<int> &zones_opp,
                                  std::vector<int> &corners_local,
                                  std::vector<int> &corners_opp,
                                  std::vector<int> &ncorners_on_zone_face,
                                  std::vector<int> &zone_faces_to_bcids,
                                  int rank);

   void ComputeLocalCornersInZone(int nzones, int ncorners);
   void ComputeCornerOffsets(int nzones);
   void ComputeZoneFaceToHalfFaceDict();
   void ComputeSharedFaces(int rank);

   int GetOppositeZone(int zone, int face);
   int GetOppositeCorner(int zone, int face, int corner, int rank);

/* ------------------------------------------------------------------------------------------------------------------ */


/* ------------------------------------------------------------------------------------------------------------------ 
   Creates array containing corner node positions, ordered by zone.
   ------------------------------------------------------------------------------------------------------------------ */
   void CreateTetonMeshCornerCoords();

/* ------------------------------------------------------------------------------------------------------------------ 
   Verifies the blueprint node contains valid blueprint structures.  Calls conduit::blueprint::mpi::verify(node).
   ------------------------------------------------------------------------------------------------------------------ */
   void verifyInput(conduit::Node &meshNode, MPI_Comm comm);

/* ------------------------------------------------------------------------------------------------------------------ 
   Class member variables shared across class methods
   Before sure to delete the TetonBlueprint class when done with it, as these structures scale with the mesh size.
   ------------------------------------------------------------------------------------------------------------------ */


   //TODO: Investigate if some of these can be made local variables and passed between methods so they are freed when
   //      the method exits.

   int nbelem = 0;
   int nhalffaces = 0;

   conduit::int32 *m_zone_to_faces;
   conduit::int32 *m_zone_to_corners;
   conduit::int32 *m_face_to_zones;

   std::map<std::pair<int, int>, int> zoneface_to_halfface;
   std::map<std::pair<int, int>, int> zoneface_to_lface;

   std::vector<std::vector<int>> zone_and_face_to_halfface;

   std::vector<bool> face_is_shared_bndry;
   std::vector<int> zoneface_to_face;
   std::vector<std::vector<int>> zone_to_faces2;
   std::vector<std::vector<int>> zone_to_corners2;
   std::vector<std::vector<int>> zone_to_nodes2;
   std::vector<std::vector<int>> face_to_zones2;
   std::vector<std::vector<int>> face_to_corners2;
   std::vector<int> corner_to_zone;
   std::vector<int> corner_to_lcorner;
   std::vector<int> corner_offsets;
   std::vector<double> corner_to_node_x;
   std::vector<double> corner_to_node_y;
   std::vector<double> corner_to_node_z;
   std::vector<int> m_face_to_bcid;

public:
   TetonBlueprint(conduit::Node &blueprintNode, conduit::Node &parametersNode)
       : mMeshNode(blueprintNode), mParametersNode(parametersNode) {}

   ~TetonBlueprint(){}

/* ------------------------------------------------------------------------------------------------------------------ 
   This is the top level call to perform all needed action to produce the set of mesh arrays needed for
   TetonConduitInterface and the Teton Fortran API.
   ------------------------------------------------------------------------------------------------------------------ */
   void OutputTetonMesh(int rank, MPI_Comm comm);
};

#endif // TetonBlueprint_HPP__
