# Migrate Oracle Sub-minute scheduler jobs to Amazon RDS for PostgreSQL or Amazon Aurora for PostgreSQL databases

This post will be covering the use cases of migrating Oracle database jobs that run at sub-minute intervals to Amazon RDS for PostgreSQL or Amazon Aurora PostgreSQL-Compatible Edition. We will demonstrate a step-by-step solution to setup the job scheduling capabilities in Amazon RDS/Aurora PostgreSQL, mirroring the capabilities of Oracle scheduler jobs, that will address the below three patterns 
1. cron like schedule 
2. sub-minute job with an interval of [0-59] seconds and 
3. Immediate/ONCE.  

Pattern 1 and 2 are in-built functionalities of pg_cron whereas pattern 3 requires us to build a custom solution. To do this, we will follow the approach outlined below
1)	Set up pg_cron extension and implement native functionalities
a)	Configure the pg_cron extension in the Amazon Aurora PostgreSQL database that provides cron-like job scheduling capabilities within PostgreSQL.
b)	Create required tables, functions and procedures to help testing the jobs.
c)	Test patterns 1 and 2 for successful execution.
2)	Implementation to schedule jobs of type Immediate/ONCE
a)	Create supporting objects in the database
b)	Test Pattern 3, Implementation and Execution of job type Immediate/ONCE 

**1. Set up pg_cron extension and implement native functionalities**

Modify the custom parameter group associated with your PostgreSQL DB instance by adding pg_cron to the shared_preload_libraries parameter value. see Amazon Aurora PostgreSQL parameters to learn more about parameter. 
Connect to the database that has rds_superuser permissions and create extension 

CREATE EXTENSION pg_cron;

By default, when you create pg_cron extension – objects related to this extension are created under postgres database and respective schedules will happen in postgres database. 
If you want to change the database you can update the static cron.database_name parameter in the parameter group, that requires restart of the database. To schedule jobs for other databases within your PostgreSQL DB instance, see the example in Scheduling a cron job for a database other than the default database.
pg_cron extension creates cron schema and has two tables cron.job and cron.job_run_details to maintain the jobs that are in queue for execution or jobs that are executed. To customize or tune pg_cron refer the documentation for more details and to modify Parameters for managing the pg_cron extension in the database parameter group.

Objects	Object Type	Usage/Functionality
Cron.job	Table	Maintains the scheduled job queue 
Cron.job_run_details	Table	Maintains the job execution run details 
Cron.schedule	Function	Schedule the job 
Cron.unschedule	Function	Unschedule the job from the queue

Below SQL script sets up a new schema named “mydemo”, creates a user with the same name, grants the user access to the cron schema, and creates a sequence and a table named instest within the mydemo schema. The instest table is designed to store records with an auto-incrementing id, a name column, and a test_date column for storing timestamps.

```
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
```



Once the table is created, schedule the job using pg_cron to run at 22:32 hrs to insert a record in instest table. Below command helps implementing method 1 that creates a schedule and the job will be queued in cron.job table, once the job executes cron.job_run_details table will be updated with the acquired job status.


**2. Implementation to schedule jobs of type Immediate/ONCE**

In this section we will focus to customize the functionality of pg_cron to closely resemble with Oracle’s dbms_job or dbms_scheduler. pg_cron doesn’t have the functionality natively to automatically create random job names and immediately unschedule the jobs post execution to avoid unintended runs. We will demonstrate the functionality by creating custom procedures and functions in PostgreSQL such as to “create random job names”, “schedule jobs to run Immediately or ONCE”, “un-scheduling from the queue”.

Since these are custom procedures and functions, you will be creating a separate utility schema called “dbms_job” and this schema will be granted to all other application schemas in the database.

```
create schema dbms_job;
create user dbms_job with password 'dbms_job';
alter schema dbms_job owner to dbms_job;
GRANT USAGE ON SCHEMA cron TO dbms_job;
```




Object Name	Functionality
dbms_job.generate_job_name	Generate custom Job name 
dbms_job.submit_delay	Schedule Job to run Immediately and/or ONCE
dbms_job.reschedule_job	the job should be unscheduled after executing ONCE or Immediately
dbms_job.check_job_completion	Cleanup the onetime jobs that are executed and still in Queue



**Generate custom Job name:**

In Oracle, you can create job using CREATE_JOB procedure to create a single job or create multiple jobs in a single transaction. With create_job procedure you can customize to have a dynamic and unique job name based on the type of job or objects in use. This can be helpful in cases where you want to ensure that each scheduled job has a distinct and identifiable name created in a single transaction.
 To create similar functionality in PostgreSQL, a custom function “generate_job_name” is created in dbms_job schema using PL/PGSQL. By default, this function will generate a random job name with a prefix “CRON_JOB$_ “. However, if your job requires a custom prefix for easy identification, input the parameter “prefix” and this is concatenated with ”$_EXECUTE_ONCE” 

```
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
```


**Schedule Job to execute Immediately**

In Oracle, a job the needs to run immediately is scheduled using RUN_JOB procedure for the provided job name. To address the similar use case of Immediate job execution in PostgreSQL, a custom procedure “submit_delay” is created in dbms_job schema using PL/PGSQL.  This procedure schedules a job using the pg_cron extension, with the provided job name and job command. The job is scheduled to run every second. After scheduling the job, the procedure retrieves the job ID and logs a notice message with the job ID and the current timestamp.

```
CREATE OR REPLACE PROCEDURE dbms_job.submit_delay( IN l_job_name text,
                                                     IN l_job text) 
LANGUAGE 'plpgsql' 
AS $body$
  DECLARE
    _job_current_seqid bigint;
  BEGIN
    
    perform cron.schedule(l_job_name, '1 second', l_job);
    SELECT CURRVAL('cron.jobid_seq')
    INTO   _job_current_seqid;
    
    -- Return completion message for the first job
    RAISE notice 'First schedule of jobid % created at %', _job_current_seqid, clock_timestamp();
  END;
  $body$;
```



**Reschedule Job**

In Oracle, you have the flexibility to declare start and end date of the scheduler job. With pg_cron you can’t specify the end date and building job types such as “Immediate” or “ONCE” could be challenging as a manual intervention is required to unschedule the job and it is nearly impossible to intervene if the jobs are created and managed within a batch job. To overcome this, a custom procedure “reschedule_job” is created that adds a functionality to stop the execution of queued jobs by rescheduling them to a past timestamp. 

```
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
  --PERFORM cron.schedule(job_name, _current_time, job_query::text);
  PERFORM cron.schedule(job_name, _current_time, _job_what);
  
  --update the job_query to query from cron.job and cron.job_run_details [Pending]
  
  _job_current_seqid := (SELECT last_value FROM cron.jobid_seq)::text;
  
  RAISE NOTICE 'Job % has been rescheduled at %', _job_current_seqid, clock_timestamp();
END;
$BODY$;

ALTER PROCEDURE dbms_job.reschedule_job(text) OWNER TO postgres;
```




**Implementation of job type Immediate/ONCE **

We will implement method 3, a simple use case of record insertion in the table using a database job scheduler and this job will be executing only ONCE. The solution has 2 part and has been detailed below.

**Part 1: Stored Procedure mydemo.proc_onetimejob_run**

This procedure is designed to generate a job name based on a provided prefix and schedule a 
one-time job to run immediately. Here's a breakdown of the procedure:
1.	The procedure takes an input parameter `job_prefix` of type `text`.
2.	It declares a variable `_job_name` of type `varchar(255)`.
3.	Inside the procedure body, it calls the function `mydemo.generate_job_name` with the provided `job_prefix` to generate a unique job name, which is stored in the `_job_name` variable.
4.	It constructs a SQL statement `l_job` that calls the function `mydemo.func_sleep_ins` with the generated `_job_name` as an argument.
5.	It uses the `dbms_job.submit_delay` function to schedule the `l_job` SQL statement to run immediately and only once.

```
CREATE OR REPLACE PROCEDURE mydemo.proc_onetimejob_run( IN job_prefix text) 
language plpgsql 
AS 
$body$
DECLARE l_job VARCHAR;_job_name     varchar(255);
BEGIN
  -- Generate a job name based on the provided prefix
  _job_name := dbms_job.generate_job_name(job_prefix);
  l_job := 'SELECT mydemo.func_sleep_ins(''' || _job_name || ''')';
  -- Create schedule to run immediately and ONCE of the defined l_job mydemo.func_sleep_insv2
  call dbms_job.submit_delay(_job_name, l_job);
end;
$body$;
ALTER PROCEDURE mydemo.proc_onetimejob_run(text) owner TO mydemo;
```


**Part 2: Function mydemo.func_sleep_ins**

This function is designed to insert a record into the mydemo.instest
 table with the provided job name and the current timestamp. Here's a breakdown of the function:
1.	The function takes an input parameter `l_job_name` of type `text`.
2.	It declares a variable `result` of type `integer`.
3.	Inside the function body, it inserts a new record into the `mydemo.instest` table with the values `'RecordInserted_by_' || l_job_name` for the `NAME` column and `clock_timestamp()` for the `test_date` column.
4.	It calls the `dbms_job.reschedule_job` function with the `l_job_name` as an argument. This function is likely used to reschedule the job to a past timestamp, ensuring that the job doesn't run more than once.
5.	It assigns the value `42` to the `result` variable.
6.	Finally, it returns the `result` value.

```
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
  
  -- Reschedule my job to a past timestamp to ensure l_job_name doesn't run more than once (newly added)
  call dbms_job.reschedule_job (l_job_name);
  -- Set the result value
  result := 42;
  -- Return the result
  return result;
end;
$body$;
ALTER FUNCTION mydemo.func_sleep_ins(text) owner TO mydemo;    
```


In Summary of the above execution, a job is created a with a prefix TESTV3_3 with a jobid 1247. From cron.job_run_details we see that job has been executed Immediately and ONCE, mydemo.instest table has a record inserted successfully. We also observed that, the schedule has been updated to past date timestamp in cron.job table which confirm it will not be executed as it is past dated. 

**Maintenance**

In order to keep pg_cron healthy, it is recommended to perform regular cleanup activity of job queue that were created to executed ONCE/Immediately. These jobs are required to be removed from the queue as they will not be executed again as their schedule is past dated. In order to have this maintenance occur at a regular frequency a custom function has been created where it identifies the job status based on job status and job name, In the below scenario we unscheduled jobs with job_name as ontimestamp with status succeeded.

Apart from having the Immediate jobs that were scheduled to run only ONCE were removed from the queue, it is utmost important to conduct a frequent maintenance of cron.job and cron.job_run_details tables as the records in cron.job_run_details are not cleaned automatically, but every user that can schedule cron jobs also has permission to delete their own cron.job_run_details records.

Especially when you have jobs that run every few seconds, it can be a good idea to clean up regularly, which can easily be done using pg_cron itself:


**Conclusion**

By combining the capabilities of the pg_cron extension and the custom procedures/functions, we achieved a robust job scheduling system in Amazon RDS/Aurora PostgreSQL, closely resembling the behavior of Oracle's dbms_job. This setup will allow us to define jobs that run at intervals of less than a minute, effectively catering to sub-minute job scheduling requirements. The execution capabilities of this custom solution will provide flexibility and efficiency in managing different types of jobs within the database.




