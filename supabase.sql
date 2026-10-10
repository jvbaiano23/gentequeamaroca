-- Gente que Ama Roça · Supabase (cole no SQL Editor e clique em Run)
create table public.products(
  id uuid primary key default gen_random_uuid(),
  category text not null, name text not null, description text not null default '',
  price_cents int not null check(price_cents>=0), stock int not null default 0 check(stock>=0),
  visible boolean not null default true, image_url text, sort int not null default 0,
  created_at timestamptz not null default now());
create table public.orders(
  id uuid primary key default gen_random_uuid(),
  code int generated always as identity (start with 1001) unique,
  token text not null default replace(gen_random_uuid()::text,'-',''),
  customer_name text not null, neighborhood text not null, phone text not null,
  status text not null default 'aguardando' check(status in ('aguardando','pago','entregue','cancelado')),
  total_cents int not null default 0, created_at timestamptz not null default now());
create table public.order_items(
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null, qty int not null check(qty>0), unit_price_cents int not null);
create table public.admins(user_id uuid primary key references auth.users(id) on delete cascade);
create index on public.order_items(product_id);

alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.admins enable row level security;

create function public.is_admin() returns boolean language sql security definer stable set search_path=public as
$$ select exists(select 1 from public.admins where user_id=auth.uid()) $$;

create policy "produtos visiveis" on public.products for select to anon,authenticated using (visible or public.is_admin());
create policy "admin escreve produtos" on public.products for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin ve pedidos" on public.orders for select to authenticated using (public.is_admin());
create policy "admin ve itens" on public.order_items for select to authenticated using (public.is_admin());

grant usage on schema public to anon, authenticated;
grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;
grant select on public.orders, public.order_items to authenticated;

create function public.order_json(p_id uuid) returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object('code',o.code,'token',o.token,'status',o.status,'total_cents',o.total_cents,
    'name',o.customer_name,'neighborhood',o.neighborhood,
    'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.name,'qty',i.qty,'unit_price_cents',i.unit_price_cents)),'[]'::jsonb) from public.order_items i where i.order_id=o.id))
  from public.orders o where o.id=p_id $$;

-- Cria o pedido e baixa o estoque na mesma operação (se faltar estoque, nada é gravado)
create function public.create_order(p_name text,p_neighborhood text,p_phone text,p_items jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o public.orders; it jsonb; p public.products; total int:=0; q int; ph text:=regexp_replace(coalesce(p_phone,''),'\D','','g');
begin
  if coalesce(trim(p_name),'')='' or coalesce(trim(p_neighborhood),'')='' or length(ph)<10 then raise exception 'Preencha nome, bairro e WhatsApp.'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Pedido vazio.'; end if;
  insert into public.orders(customer_name,neighborhood,phone) values(left(trim(p_name),80),left(trim(p_neighborhood),80),ph) returning * into o;
  for it in select value from jsonb_array_elements(p_items) loop
    q:=(it->>'qty')::int;
    select * into p from public.products where id=(it->>'id')::uuid and visible for update;
    if not found or q<=0 or p.stock<q then raise exception 'Estoque insuficiente de %.', coalesce(p.name,'um item'); end if;
    update public.products set stock=stock-q where id=p.id;
    insert into public.order_items(order_id,product_id,name,qty,unit_price_cents) values(o.id,p.id,p.name,q,p.price_cents);
    total:=total+q*p.price_cents;
  end loop;
  update public.orders set total_cents=total where id=o.id;
  return public.order_json(o.id);
end $$;

create function public.get_order(p_code int,p_token text) returns jsonb language sql security definer set search_path=public as $$
  select public.order_json(id) from public.orders where code=p_code and token=p_token $$;

create function public.adjust_stock(p_id uuid,p_delta int) returns int language plpgsql security definer set search_path=public as $$
declare s int; begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  update public.products set stock=greatest(0,stock+p_delta) where id=p_id returning stock into s; return s; end $$;

-- Muda o status; cancelar devolve o estoque (e não dá para reabrir pedido cancelado)
create function public.set_order_status(p_id uuid,p_status text) returns void language plpgsql security definer set search_path=public as $$
declare old text; begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  select status into old from public.orders where id=p_id for update;
  if old='cancelado' then raise exception 'Pedido cancelado não pode ser reaberto.'; end if;
  if p_status='cancelado' then
    update public.products pr set stock=pr.stock+i.qty from public.order_items i where i.order_id=p_id and i.product_id=pr.id;
  end if;
  update public.orders set status=p_status where id=p_id; end $$;

revoke all on function public.order_json(uuid), public.create_order(text,text,text,jsonb), public.get_order(int,text),
  public.adjust_stock(uuid,int), public.set_order_status(uuid,text), public.is_admin() from public, anon, authenticated;
grant execute on function public.create_order(text,text,text,jsonb), public.get_order(int,text), public.is_admin() to anon, authenticated;
grant execute on function public.adjust_stock(uuid,int), public.set_order_status(uuid,text) to authenticated;

-- Fotos dos produtos
insert into storage.buckets(id,name,public) values('produtos','produtos',true) on conflict (id) do nothing;
create policy "admin envia fotos" on storage.objects for insert to authenticated with check(bucket_id='produtos' and public.is_admin());

-- DEPOIS de criar o login da cliente (Authentication > Users), rode trocando o e-mail:
-- insert into public.admins select id from auth.users where email='EMAIL_DA_CLIENTE';

-- Produtos iniciais (do cardápio atual)
insert into public.products(category,name,description,price_cents,stock,visible,sort) values
('variados','Queijo parmesão ralado fino 50 g','Ideal para acompanhar pratos de massa, cachorro-quente e muito mais.',550,10,true,0),
('variados','Iogurte Artesanal Maracujá 1 L','Com açúcar',1800,5,true,1),
('variados','Iogurte Artesanal Ameixa 1 L','Com açúcar',1800,5,true,2),
('variados','Leite de Vaca Puro Congelado 1 L','Leite de vaca puro, sem conservantes.',990,8,true,3),
('variados','Farinha de Mandioca 900 g','Farinha de mandioca artesanal',890,15,true,4),
('variados','Bananada Tradicional zero açúcar','10 un. de 25 g por pacote',1500,20,true,5),
('variados','Iogurte Artesanal Morango 1 L','Com açúcar',1800,5,true,6),
('variados','Iogurte Artesanal Natural 1 L','Com açúcar',1800,5,true,7),
('frigorifico','Maminha do Sol (peça)','Carne do sol de maminha selecionada, pesando de 900 g a 1,1 kg.',7290,3,true,8),
('frigorifico','Almôndegas de Costela 500 g','Temperada, média de 500 g.',2990,10,true,9),
('frigorifico','Hambúrguer de Patinho, kit 4','Baixo teor de gordura, perfeito para uma alimentação leve. 4 unidades de 100 g.',2500,8,true,10),
('frigorifico','Carne do Sol 500 g','Macia, em cubos, pronta para o preparo. Não precisa escaldar.',3200,12,true,11),
('frigorifico','Espetinho Bovino, 10 un.','Carne suculenta, já temperada e pronta para saborear. Perfeito para churrasco.',3990,6,true,12),
('frigorifico','Hambúrguer de Acém, kit 4','Acém e apaga brasa, 4 unidades de 100 g, com a gordura ideal para um burguer inesquecível.',2000,4,true,13),
('frigorifico','Lombo Bovino Temperado (peça)','Média de 1,35 kg. Calabresa, bacon e temperos.',7690,2,true,14),
('iguarias','Linguiça de Charque com Queijo','',2890,8,true,15),
('iguarias','Sarapatel de Bode 1 kg','Temperado, pronto pra jogar na panela.',4800,3,true,16),
('iguarias','Buchada de Cordeiro 1 kg','Temperada, pronta pra jogar na panela.',5700,2,true,17),
('iguarias','Linguiça de Bode','',2890,8,true,18),
('pizza','Mini Pizza de Calabresa','Unidade. 10 unidades por R$ 80,00.',850,25,true,19),
('laticinios','Manteiga, pote 200 g','',990,20,true,20),
('laticinios','Ovo Caipira G, dúzia','',1600,15,true,21),
('laticinios','Requeijão de Raspa 500 g','',2500,10,true,22),
('laticinios','Requeijão Tradicional Sergipano 500 g','',2500,10,true,23),
('laticinios','Mussarela Artesanal, barra 500 g','',2500,8,true,24);
