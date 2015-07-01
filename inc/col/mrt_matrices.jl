#! Initializes the default multiple relaxation time transformation matrix
macro DEFAULT_MRT_M()
  return :([
             1.0    1.0    1.0    1.0    1.0    1.0    1.0    1.0    1.0;
            -1.0   -1.0   -1.0   -1.0    2.0    2.0    2.0    2.0   -4.0;
            -2.0   -2.0   -2.0   -2.0    1.0    1.0    1.0    1.0    4.0;
             1.0    0.0   -1.0    0.0    1.0   -1.0   -1.0    1.0    0.0;
            -2.0    0.0    2.0    0.0    1.0   -1.0   -1.0    1.0    0.0;
             0.0    1.0    0.0   -1.0    1.0    1.0   -1.0   -1.0    0.0;
             0.0   -2.0    0.0    2.0    1.0    1.0   -1.0   -1.0    0.0;
             1.0   -1.0    1.0   -1.0    0.0    0.0    0.0    0.0    0.0;
             0.0    0.0    0.0    0.0    1.0   -1.0    1.0   -1.0    0.0;
           ]);
end

#! Fallah relaxation coefficient for s77, s88
#!
#! \param mu Dynamic viscosity
#! \param rho Local density
#! \param c_ssq Lattice speed of sound squared
#! \param dt Change in time
#! \return Fallah relaxation coefficient for s77 and s88
macro fallah_8(mu, rho, cssq, dt)
  return :(1.0/($mu / ($rho * $cssq * $dt) + 0.5));
end

#! Fallah relaxation matrix
#!
#! \param mu Dynamic viscosity
#! \param rho Local density
#! \param c_ssq Lattice speed of sound squared
#! \param dt Change in time
#! \return Fallah relaxation matix
function S_fallah(mu::Number, rho::Number, cssq::Number,
	                dt::Number)
	const s_8 = @fallah_8(mu, rho, cssq, dt);
	return spdiagm([1.1; 1.1; 0.0; 1.1; 0.0; 1.1; s_8; s_8; 0.0]);
end

#! Chen relaxation matrix
#!
#! \param omega Collision frequency
#! \return Chen relaxation matix
function S_chen(mu::Number, rho::Number, cssq::Number,
	              dt::Number)
  omega = @omega(mu, cssq, dt);
  return spdiagm([1.1; 1.0; 0.0; 1.2; 0.0; 1.2; omega; omega; 0.0]);
end