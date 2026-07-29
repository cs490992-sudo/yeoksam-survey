# 공유 schema 적용 전 확인

이 문서는 `supabase/migrations/001_survey_core.sql`을 실제로 적용하기 전에 Supabase SQL Editor에서 **읽기 전용으로 직접 실행할 확인 쿼리**를 기록합니다. 쿼리는 schema를 변경하지 않으며 migration에서 자동 실행되지 않습니다.

## 컬럼 확인

다음 쿼리로 `profiles`, `clients`, `programs`의 컬럼명, PostgreSQL 표시 타입, 내부 `udt_name`, NULL 허용 여부를 확인합니다.

```sql
select
  table_schema,
  table_name,
  ordinal_position,
  column_name,
  data_type,
  udt_name,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name in ('profiles', 'clients', 'programs')
order by table_name, ordinal_position;
```

## 확인된 실제 구조

읽기 전용 조회로 다음 구조를 확인했습니다.

- `clients.id`: `uuid` primary key
- `clients.organization_id`: `uuid` not null, `public.organizations(id)` 참조
- `clients.name`: `text` not null
- `clients.photo_path`: `text` null
- `clients.is_active`: `boolean` not null
- `programs.id`: `uuid` primary key
- `programs.organization_id`: `uuid` not null, `public.organizations(id)` 참조
- `programs.name`: `text` not null
- `programs.is_active`: `boolean` not null
- `profiles.id`: `uuid` primary key, `auth.users(id)` 참조
- `profiles.organization_id`: `uuid` not null, `public.organizations(id)` 참조
- `profiles.role`: `public.user_role` enum not null (`admin`, `staff`)
- `profiles.is_active`: `boolean` not null

따라서 조사 migration의 `organization_id`, `program_id`, `client_id`는 UUID로 연결하며, 확인된 공유 테이블에는 어떠한 변경도 적용하지 않습니다.

## Primary key와 Foreign key 확인

다음 쿼리는 세 공유 테이블에 설정된 primary key와 foreign key의 컬럼 및 참조 대상을 표시합니다.

```sql
select
  source_ns.nspname as table_schema,
  source.relname as table_name,
  constraint_info.conname as constraint_name,
  constraint_info.contype as constraint_type,
  source_column.attname as column_name,
  target_ns.nspname as referenced_table_schema,
  target.relname as referenced_table_name,
  target_column.attname as referenced_column_name
from pg_catalog.pg_constraint constraint_info
join pg_catalog.pg_class source
  on source.oid = constraint_info.conrelid
join pg_catalog.pg_namespace source_ns
  on source_ns.oid = source.relnamespace
join lateral unnest(constraint_info.conkey) with ordinality source_key(attnum, position)
  on true
join pg_catalog.pg_attribute source_column
  on source_column.attrelid = source.oid
 and source_column.attnum = source_key.attnum
left join pg_catalog.pg_class target
  on target.oid = constraint_info.confrelid
left join pg_catalog.pg_namespace target_ns
  on target_ns.oid = target.relnamespace
left join lateral unnest(constraint_info.confkey) with ordinality target_key(attnum, position)
  on target_key.position = source_key.position
left join pg_catalog.pg_attribute target_column
  on target_column.attrelid = target.oid
 and target_column.attnum = target_key.attnum
where source_ns.nspname = 'public'
  and source.relname in ('profiles', 'clients', 'programs')
  and constraint_info.contype in ('p', 'f')
order by source.relname, constraint_info.contype, constraint_info.conname, source_key.position;
```

`constraint_type`의 `p`는 primary key, `f`는 foreign key입니다. 향후 공유 schema가 변경되면 migration 적용 전에 다시 확인하며, 공유 테이블이나 Storage 정책을 이 확인 과정에서 변경하지 않습니다.
