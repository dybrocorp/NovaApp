CREATE OR REPLACE FUNCTION public.uuid_generate_v4() RETURNS uuid LANGUAGE sql VOLATILE AS $$ SELECT gen_random_uuid() $$;
CREATE OR REPLACE FUNCTION public.gen_random_bytes(int) RETURNS bytea LANGUAGE sql VOLATILE AS $$
  SELECT decode(string_agg(lpad(to_hex((random()*255)::int),2,'0'), ''), 'hex') FROM generate_series(1,$1)
$$;
