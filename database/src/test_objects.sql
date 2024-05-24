

create schema mydemo;

create user mydemo with password 'mydemo';

alter schema mydemo owner to mydemo;

GRANT USAGE ON SCHEMA cron TO mydemo;

create sequence mydemo.instest_id_seq;

CREATE TABLE IF not EXISTS mydemo.instest
             (
                          id INTEGER NOT NULL DEFAULT NEXTVAL('instest_id_seq'),
                          name text collate pg_catalog."default",
                          test_date timestamp without TIME zone
             );  


-- PART 1

CREATE OR REPLACE PROCEDURE mydemo.proc_onetimejob_run( IN job_prefix text) 
language plpgsql 
AS 
$body$
DECLARE l_job VARCHAR;_job_name     varchar(255);
BEGIN
  -- Generate a job name based on the provided prefix
  _job_name := dbms_job.generate_job_name(job_prefix);
  l_job := 'SELECT mydemo.func_sleep_ins(''' || _job_name || ''')';
  call dbms_job.submit_delay(_job_name, l_job);
end;
$body$;

ALTER PROCEDURE mydemo.proc_onetimejob_run(text) owner TO mydemo;

-- Part 2

CREATE OR REPLACE FUNCTION mydemo.func_sleep_ins( l_job_name text)
returns        integer 
language 'plpgsql' 
AS 
$body$
DECLARE result integer;
begin
  -- Insert Jobs
  INSERT INTO mydemo.instest
              (
                          NAME,
                          test_date
              )
              VALUES
              (
                          'Before_'
                          || l_job_name ,
                          clock_timestamp()
              );
  
  call dbms_job.reschedule_job (l_job_name);
  -- Set the result value
  result := 42;
  -- Return the result
  return result;
end;
$body$;

ALTER FUNCTION mydemo.func_sleep_ins(text) owner TO mydemo;    
