-- Exercise the native decoder on synthetic input inside the disposable CI DB.
CREATE TEMP TABLE decoder_probe (id integer, geom geometry, label text);
DO $$
DECLARE
  sample bytea;
  decoded text;
  marker integer;
  item record;
BEGIN
  IF current_setting('server_version_num') <> '170011' OR postgis_lib_version() <> '3.6.4' THEN
    RAISE EXCEPTION 'CI database version differs from the reviewed build';
  END IF;
  SELECT ST_AsFlatGeobuf(q) INTO sample
    FROM (SELECT ST_Point(1, 2) AS geom, 'ci-sentinel'::text AS label) q;
  SELECT label INTO STRICT decoded FROM ST_FromFlatGeobuf(NULL::decoder_probe, sample);
  IF decoded IS DISTINCT FROM 'ci-sentinel' THEN RAISE EXCEPTION 'native round trip failed'; END IF;
  marker := position(convert_to('ci-sentinel', 'UTF8') IN sample);
  IF marker < 5 OR substring(sample FROM marker - 4 FOR 4) <> decode('0b000000', 'hex') THEN
    RAISE EXCEPTION 'unexpected FlatGeobuf string encoding';
  END IF;

  FOR item IN SELECT * FROM (VALUES
    (decode('6667620366676201010203', 'hex'), 'flatgeobuf: truncated size prefix'),
    (decode('6667620366676201ffffffff', 'hex'), 'flatgeobuf: size prefix exceeds remaining input'),
    (overlay(sample PLACING decode('ff000000', 'hex') FROM marker - 4 FOR 4),
     'flatgeobuf: decode_properties: string length exceeds buffer')
  ) v(payload, expected) LOOP
    BEGIN
      PERFORM * FROM ST_FromFlatGeobuf(NULL::decoder_probe, item.payload);
      RAISE EXCEPTION 'malformed FlatGeobuf was accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> item.expected THEN RAISE; END IF;
    END;
  END LOOP;
END $$;
