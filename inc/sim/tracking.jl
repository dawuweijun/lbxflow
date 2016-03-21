# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

using ArrayViews

#! Check to see if a pair of indices fall inside a bounds
function inbounds(i::Int, j::Int, sbounds::Matrix{Int64})
  const nbounds = size(sbounds, 2);
  for n=1:nbounds
    if i < sbounds[1,n]; return false; end
    if i > sbounds[2,n]; return false; end
    if j < sbounds[3,n]; return false; end
    if j > sbounds[4,n]; return false; end
  end
  return true;
end

#! Simulate mass transfer across interface cells
#!
#! \param sim FreeSurfSim object
#! \param sbounds Bounds where fluid can be streaming
function masstransfer!(sim::FreeSurfSim, sbounds::Matrix{Int64})
  t   = sim.tracker;
  lat = sim.lat;
  msm = sim.msm;

  for node in t.interfacels
    i, j = node.val;
    @assert(t.state[i,j] == INTERFACE, "All cells in the interface list " *
            "should be in the 'INTERFACE' state");
    if inbounds(i, j, sbounds)
      for k=1:lat.n
        i_nbr = i + lat.c[1,k];
        j_nbr = j + lat.c[2,k];
        if !inbounds(i_nbr, j_nbr, sbounds) || t.state[i_nbr,j_nbr] == GAS
          continue;
        elseif  t.state[i_nbr,j_nbr] == FLUID

          const opk   = opp_lat_vec(lat, k);
          t.M[i,j]   += lat.f[opk,i_nbr,j_nbr] - lat.f[k,i,j] # m in - m out

        elseif  t.state[i_nbr,j_nbr] == INTERFACE 

          const opk   = opp_lat_vec(lat, k);
          t.M[i,j]   += ((t.eps[i,j] + t.eps[i_nbr,j_nbr]) / 2 * 
                         (lat.f[opk,i_nbr,j_nbr] - lat.f[k,i,j]));

        else
          error("state not understood or invalid");
        end
      end
    end
  end
end

# Update fluid fraction of each interface cell
function _update_fluid_fraction!(sim::FreeSurfSim, kappa::Real)
  t                 = sim.tracker;
  const ni, nj      = size(t.state);
  new_empty_cells   = DoublyLinkedList{Tuple{Int, Int}}();
  new_fluid_cells   = DoublyLinkedList{Tuple{Int, Int}}();
  
  for node in interfacels
    const i, j  =   node.val;
    t.eps[i, j] =   t.M[i, j] / sim.msm.rho[i, j];

    if      t.M[i, j] > (1 + kappa) * sim.msm.rho[i, j]
      push!(new_fluid_cells, (i, j));
    elseif  t.M[i, j] < -kappa * sim.msm.rho[i, j]
      push!(new_empty_cells, (i, j));
    end

  end

  return new_empty_cells, new_fluid_cells;
end

# Update cell states and redistribute mass to neighborhoods
function _update_cell_states!(sim::FreeSurfSim, sbounds::Matrix{Int64},
                              feq_f::LBXFunction,
                              new_empty_cells::DoublyLinkedList{Tuple{Int, Int}},
                              new_fluid_cells::DoublyLinkedList{Tuple{Int, Int}})

  lat           = sim.lat;
  msm           = sim.msm;
  t             = sim.tracker;

  const ni, nj  = size(t.state);
  const nk      = length(lat.w);

  for node in new_fluid_cells # First the neighborhood of all filled cells are prepared
    const i, j      =     node.val;
    t.state[i, j]   =     FLUID;

    # Calculate the total density and velocity of the neighborhood
    ρ_sum           =     0.0;
    u_sum           =     Float64[0.0; 0.0];
    counter::UInt   =     0;
    for k=1:nk-1
      const i_nbr     =     i + lat.c[1, k];
      const j_nbr     =     j + lat.c[2, k];

      if (i_nbr < 1 || i_nbr > ni || j_nbr < 1 || j_nbr > nj ||
          t.state[i_nbr, j_nbr] == GAS)
        continue;
      end

      counter         +=     1;

      ρ_sum           +=     msm.rho[i_nbr, j_nbr];
      u_sum           +=     msm.u[:, i_nbr, j_nbr];
    end
    ρ_avg           =       ρ_sum / counter;
    u_avg           =       u_sum / counter;

    # Construct interface cells from neighborhood average at equilibrium
    for k=1:nk-1
      const i_nbr     =     i + lat.c[1, k];
      const j_nbr     =     j + lat.c[2, k];

      if i_nbr < 1 || i_nbr > ni || j_nbr < 1 || j_nbr > nj
        continue;
      end

      # If it is already an interface cell, make sure it is not emptied
      if t.state[i_nbr, j_nbr] == INTERFACE
        remove!(new_empty_cells, (i_nbr, j_nbr));
      elseif states[i_nbr, j_nbr] == GAS
        t.state[i_nbr, j_nbr] = INTERFACE;
        for kk=1:nk
          lat.f[kk, i_nbr, j_nbr]   =   feq_f(ρ_avg, lat.w[kk], lat.c[:, kk], 
                                              u_avg);
        end
        push!(t.interfacels, (i_nbr, j_nbr));
      end
    end # end reflag neighbors loop
  end

  for node in new_empty_cells # convert emptied cells to gas cells
    const i, j      =     node.val;
    t.state[i, j]   =     GAS;
    remove!(t.interfacels, (i, j));

    for k=1:nk-1
      const i_nbr     =     i + lat.c[1, k];
      const j_nbr     =     j + lat.c[2, k];

      if (i_nbr >= 1 && i_nbr <= ni && j_nbr >= 1 && j_nbr <= nj &&
          states[i_nbr, j_nbr] == FLUID)
        t.state[i_nbr, j_nbr] =  INTERFACE;
        push!(t.interfacels, (i_nbr, j_nbr));
      end
    end
  end

  # Redistribute excess mass
  for node in new_fluid_cells # Redistribute excess mass from new fluid cells
    const i, j      =     node.val;
    
    cells_to_redist_to  =     DoublyLinkedList{Tuple{Int, Int}}();
    counter::UInt       =     0;

    # Construct interface cells from neighborhood average at equilibrium
    for k=1:nk-1
      const i_nbr     =     i + c[1, k];
      const j_nbr     =     j + c[2, k];

      if (i_nbr >= 1 && i_nbr <= ni && j_nbr >= 1 && j_nbr <= nj &&
          t.state[i_nbr, j_nbr] == INTERFACE)
        push!(cells_to_redist_to, (i_nbr, j_nbr));
        counter +=  1;
      end
    end # find inteface loop

    # redistribute mass amoung valid neighbors
    const mex = t.M[i, j] - msm.rho[i, j];
    for node in cells_to_redist_to
      const ii, jj      =   node.val;
      t.M[ii, jj]      +=   mex; 
      t.eps[ii, jj]     =   t.M[ii, jj] / msm.rho[ii, jj];
    end

    t.M[i, j]   = msm.rho[i, j]; # set mass to local ρ
    t.eps[i, j] = 1.0;
  end

  # TODO consider putting mass distribution in a kernal function
  for node in new_empty_cells # Redistribute excess mass from emptied cells
    const i, j      =     node.val;
    
    cells_to_redist_to  =     DoublyLinkedList{Tuple{Int, Int}}();
    counter::UInt       =     0;

    # Construct interface cells from neighborhood average at equilibrium
    for k=1:nk-1
      const i_nbr     =     i + c[1, k];
      const j_nbr     =     j + c[2, k];

      if (i_nbr >= 1 && i_nbr <= ni && j_nbr >= 1 && j_nbr <= nj &&
          t.state[i_nbr, j_nbr] == INTERFACE)
        push!(cells_to_redist_to, (i_nbr, j_nbr));
        counter +=  1;
      end
    end # find inteface loop

    # redistribute mass amoung valid neighbors
    const mex = t.M[i, j];
    for node in cells_to_redist_to
      const ii, jj      =   node.val;
      t.M[ii, jj]      +=   mex;
      t.eps[ii, jj]     =   t.M[ii, jj] / msm.rho[ii, jj];
    end

    t.M[i, j]   = 0.0;
    t.eps[i, j] = 0.0;
  end
end

#! Update cell states of tracker
#!
#! \param sim FreeSurfSim object
#! \param sbounds Bounds where fluid can be streaming
function update!(sim::FreeSurfSim, sbounds::Matrix{Int64},
                 feq_f::LBXFunction, kappa=1.0e-3)
  new_empty_cells, new_fluid_cells  =   _update_fluid_fraction!(sim, kappa);
  _update_cell_states!(sim, sbounds, feq_f, new_empty_cells, new_fluid_cells);
end

# kernal function for interface f reconstruction
function _f_reconst_ij!(lat::Lattice, msm::MultiscaleMap, feq_f::LBXFunction,
                        rho_g::Real, k::Int)
  const opp_k         =   opp_lat_vec(lat, k);
  const u_ij          =   msm.u[:, i, j];
  lat.f[opp_k, i, j]  =   (feq_f(rho_g, lat.w[k], lat.c[:, k], u_ij) +
                           feq_f(rho_g, lat.w[opp_k], lat.c[:, opp_k], u_ij) -
                           lat.f[k, i, j]);
end

#! Reconstruct distribution functions at interface
#!
#! \param sim       Free surface simulation object
#! \param t         Mass tracker
#! \param ij        Tuple of i and j indices on grid
#! \param sbounds   Bounds where fluid can be streaming
#! \param rho_g     Atmospheric pressure
function f_reconst!(sim::FreeSurfSim, t::Tracker, ij::Tuple{Int64, Int64},
                    sbounds::Matrix{Int64}, feq_f::LBXFunction, rho_g::Real)
  const n     = _unit_normal(t, ij);
  const i, j  = ij;
  lat         = sim.lat;
  msm         = sim.msm;

  # reconstruct f from gas cells
  for k = 1:lat.n-1
    const i_nbr   =   i + lat.c[1,k];
    const j_nbr   =   j + lat.c[2,k];

    if (i_nbr < 1 || i_nbr > ni || j_nbr < 1 || j_nbr > nj ||
        t.state[i_nbr, j_nbr] == GAS)
      _f_reconst_ij!(lat, msm, feq_f, rho_g, k);
    end
  end

  # reconstruct f normal to interface (conservation of linear momentum)
  for k = 1:lat.n-1
    c = lat.c[:,k]; # TODO: consider using an ArrayView here
    if dot(n, c) >= 0
      _f_reconst_ij!(lat, msm, feq_f, rho_g, k);
    end
  end
end

#! Determine unit normal to interface
#!
#! \param t Mass tracker
#! \param ij i and j indices of grid cell
function _unit_normal(t::Tracker, ij::Tuple{Int64, Int64})
  const ni, nj      =   size(t.state);
  const i, j        =   ij;

  # TODO consider using heuristic to tell if we should attach to wall
  const eps_il      =   (i <= 1)  ? 0.0 : t.eps[i-1, j];
  const eps_ir      =   (i >= ni) ? 0.0 : t.eps[i+1, j];
  const eps_jd      =   (j <= 1)  ? 0.0 : t.eps[i, j-1];
  const eps_ju      =   (j >= nj) ? 0.0 : t.eps[i, j+1];

  return 1/2 * Float64[eps_il - eps_ir; eps_jd - eps_ju];
end
