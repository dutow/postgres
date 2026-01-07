/* src/test/modules/test_hba_guc/test_hba_guc--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION test_hba_guc" to load this file. \quit

-- Function to get current value of test_hba_guc.string_var
CREATE FUNCTION get_test_hba_string()
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

-- Function to get current value of test_hba_guc.int_var
CREATE FUNCTION get_test_hba_int()
RETURNS integer
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

-- Function to get current value of test_hba_guc.bool_var
CREATE FUNCTION get_test_hba_bool()
RETURNS boolean
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
