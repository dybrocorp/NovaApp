CREATE TABLE devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id UUID,            -- tipo INCOMPATIBLE a propósito
  nova_id TEXT
);
