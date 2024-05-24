CREATE EXTENSION pg_cron;

create schema dbms_job;
create user dbms_job with password 'dbms_job';
alter schema dbms_job owner to dbms_job;
GRANT USAGE ON SCHEMA cron TO dbms_job;

CREATE OR replace FUNCTION dbms_job.generate_job_name( prefix text) 
returns text 
LANGUAGE 'plpgsql' 
cost 100 volatile 
PARALLEL unsafe
AS
  $body$
  DECLARE
    _job_id text;
  BEGIN
    _job_id :=
    (
           SELECT last_value + 1
           FROM   cron.jobid_seq)::text;
    IF prefix IS NULL THEN
      RETURN 'CRON_JOB$_'
      || _job_id;
    ELSE
      RETURN prefix
      || '$_EXECUTE_ONCE'
      || _job_id;
    END IF;
  END;
  $body$;


CREATE OR REPLACE PROCEDURE dbms_job.submit_delay( IN l_job_name text,
                                                     IN l_job text) 
LANGUAGE 'plpgsql' 
AS $body$
  DECLARE
    output text; --unused
    _job_name VARCHAR(255); --unused
    _current_time text; --unused
    _current_timestamp timestamp := clock_timestamp(); --unused
    _job_current_seqid bigint;
  BEGIN
    
    perform cron.schedule(l_job_name, '1 second', l_job);
    SELECT CURRVAL('cron.jobid_seq')
    INTO   _job_current_seqid;
    
    -- Return completion message for the first job
    RAISE notice 'First schedule of jobid % created at %', _job_current_seqid, clock_timestamp();
  END;
  $body$;


CREATE OR REPLACE PROCEDURE dbms_job.reschedule_job(
	IN job_name text)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
  _current_time text;
  _job_current_seqid bigint;
  _job_what text;
BEGIN
  SELECT to_char(clock_timestamp() - interval '1 minute', 'MI HH24 DD MM *') INTO _current_time;
  
  _job_what := (select distinct j.command from cron.job_run_details j JOIN cron.job jd ON j.jobid = jd.jobid WHERE jd.jobname = job_name)::text;
  PERFORM cron.schedule(job_name, _current_time, _job_what);
  
  _job_current_seqid := (SELECT last_value FROM cron.jobid_seq)::text;
  
  RAISE NOTICE 'Job % has been rescheduled at %', _job_current_seqid, clock_timestamp();
END;
$BODY$;

ALTER PROCEDURE dbms_job.reschedule_job(text) OWNER TO postgres;


CREATE OR replace FUNCTION mydemo.check_job_completion( ) 
returns void 
LANGUAGE 'plpgsql' 
cost 100 volatile 
PARALLEL unsafe
AS
  $body$
  DECLARE
    _job_name VARCHAR(255) := 'onetimestamp';
    _job_status text;
  BEGIN
    -- Get the status of the job
    SELECT   j.status
    INTO     _job_status
    FROM     cron.job_run_details j
    join     cron.job jd
    ON       j.jobid = jd.jobid
    WHERE    jd.jobname = _job_name
    ORDER BY j.end_time DESC limit 1;
    
    -- Check if the job has completed
    IF _job_status = 'succeeded' THEN
      -- Unscheduling the job
      perform cron.unschedule(_job_name);
      RAISE notice 'Job "%s" is successfully unscheduled.', _job_name;
    ELSE
      RAISE warning 'Job "%s" is either running or has not completed yet.', _job_name;
    END IF;
  END;
  $body$;
