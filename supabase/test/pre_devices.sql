-- Simula un despliegue previo con una tabla `devices` de otra forma
CREATE TABLE devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID,
  name TEXT
);
