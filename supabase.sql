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

-- ===================================================================
-- PARTE 2 · Admin v2 (fundações aplicadas em 2026-10 via migração no
-- Supabase). Tudo aditivo: não altera nem remove nada da Parte 1, e o
-- site do comprador (index.html) e o admin.html continuam funcionando
-- exatamente como antes. Documentado aqui para refletir o banco real.
-- ===================================================================

-- Configurações gerais (chave/valor). Hoje só guarda o status do cardápio.
create table public.settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.settings(key, value) values ('menu_status', '"aberto"'::jsonb);

alter table public.settings enable row level security;
create policy "leitura publica settings" on public.settings for select to anon, authenticated using (true);
create policy "admin escreve settings" on public.settings for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.settings to anon, authenticated;
grant insert, update, delete on public.settings to authenticated;

-- Produtos: custo (pra calcular margem), estoque mínimo (alerta) e combo
-- (ex.: "10 un. por R$ 80" vira automático quando combo_qty/combo_price
-- forem usados no cálculo do carrinho do site).
alter table public.products
  add column cost_cents int not null default 0 check (cost_cents >= 0),
  add column stock_min int not null default 1 check (stock_min >= 0),
  add column combo_qty int check (combo_qty is null or combo_qty > 0),
  add column combo_price_cents int check (combo_price_cents is null or combo_price_cents >= 0);

-- Pedidos: endereço completo, desconto, taxa de entrega (existe mas não é
-- usada pelo admin-v2 hoje porque a cliente não cobra entrega separada),
-- pago/não pago, forma de pagamento, nome do entregador (campo livre,
-- sem cadastro de equipe), e o novo status de preparo — a coluna antiga
-- "status" continua existindo e sendo atualizada em paralelo, então o
-- index.html (link de resumo do pedido) não precisa de nenhuma mudança.
alter table public.orders
  add column address text,
  add column discount_cents int not null default 0 check (discount_cents >= 0),
  add column delivery_fee_cents int not null default 0 check (delivery_fee_cents >= 0),
  add column paid boolean not null default false,
  add column stock_deducted boolean not null default false,
  add column payment_method text check (payment_method is null or payment_method in ('Pix','Cartão')),
  add column courier_name text,
  add column fulfillment_status text not null default 'pendente'
    check (fulfillment_status in ('pendente','em_preparo','pronto','a_caminho','chegou','entregue','cancelado'));

-- Clientes (cadastro automático: nome, telefone, endereço, histórico).
-- A chave é o telefone: mesmo número = mesmo cliente, soma pedidos e
-- atualiza nome/endereço; números diferentes viram clientes diferentes.
create table public.customers (
  phone text primary key,
  name text not null,
  address text,
  neighborhood text,
  total_orders int not null default 0,
  total_spent_cents int not null default 0,
  last_order_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.customers enable row level security;
create policy "admin ve clientes" on public.customers for select to authenticated using (public.is_admin());
create policy "admin escreve clientes" on public.customers for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update on public.customers to authenticated;

-- Lançamentos financeiros: toda venda marcada como "paga" vira uma
-- receita sozinha (e some de lá se desmarcar); despesas são manuais.
create table public.financial_entries (
  id uuid primary key default gen_random_uuid(),
  entry_date date not null default current_date,
  kind text not null check (kind in ('receita','despesa')),
  category text not null default 'Vendas',
  payment_method text not null default 'Pix',
  amount_cents int not null,
  order_id uuid references public.orders(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);
create unique index financial_entries_order_unique
  on public.financial_entries(order_id) where kind = 'receita' and order_id is not null;
alter table public.financial_entries enable row level security;
create policy "admin ve financeiro" on public.financial_entries for select to authenticated using (public.is_admin());
create policy "admin escreve financeiro" on public.financial_entries for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.financial_entries to authenticated;

-- Gatilhos: cadastram/atualizam o cliente e o total gasto sozinhos,
-- sem precisar mexer em create_order nem no index.html.
create function public.upsert_customer_from_order() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.customers(phone, name, address, neighborhood, total_orders, last_order_at)
  values (new.phone, new.customer_name, new.address, new.neighborhood, 1, new.created_at)
  on conflict (phone) do update set
    name = excluded.name,
    address = coalesce(excluded.address, public.customers.address),
    neighborhood = coalesce(excluded.neighborhood, public.customers.neighborhood),
    total_orders = public.customers.total_orders + 1,
    last_order_at = new.created_at;
  return new;
end $$;
create trigger trg_upsert_customer after insert on public.orders
for each row execute function public.upsert_customer_from_order();

create function public.update_customer_spend() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.paid and not old.paid then
    update public.customers set total_spent_cents = total_spent_cents + new.total_cents where phone = new.phone;
  elsif old.paid and not new.paid then
    update public.customers set total_spent_cents = greatest(0, total_spent_cents - new.total_cents) where phone = new.phone;
  end if;
  return new;
end $$;
create trigger trg_customer_spend after update of paid on public.orders
for each row execute function public.update_customer_spend();
-- Funções de gatilho não devem ser chamadas direto (só pelo próprio gatilho).
revoke all on function public.upsert_customer_from_order(), public.update_customer_spend() from public, anon, authenticated;

-- Aceitar pedido: só AQUI o estoque é baixado (antes disso fica
-- "pendente" sem mexer no estoque — pedida explícita da cliente).
create function public.accept_order(p_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare it record; o public.orders;
begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  select * into o from public.orders where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if o.stock_deducted then raise exception 'Estoque já baixado para este pedido.'; end if;
  if o.fulfillment_status <> 'pendente' then raise exception 'Pedido não está mais pendente.'; end if;
  for it in select oi.product_id, oi.qty, oi.name from public.order_items oi where oi.order_id = p_id loop
    if it.product_id is not null then
      update public.products set stock = stock - it.qty where id = it.product_id and stock >= it.qty;
      if not found then raise exception 'Estoque insuficiente de %.', it.name; end if;
    end if;
  end loop;
  update public.orders set fulfillment_status = 'em_preparo', stock_deducted = true, status = 'pago' where id = p_id;
  return public.order_json(p_id);
end $$;

-- Muda o status de preparo (Em preparação → Pronto → No caminho →
-- Chegou → Entregue). Cancelar devolve o estoque, só se já tinha
-- sido baixado.
create function public.set_fulfillment_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path=public as $$
declare was_deducted boolean;
begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  if p_status not in ('pendente','em_preparo','pronto','a_caminho','chegou','entregue','cancelado') then
    raise exception 'Status inválido.';
  end if;
  select stock_deducted into was_deducted from public.orders where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if p_status = 'cancelado' then
    if was_deducted then
      update public.products pr set stock = stock + i.qty
      from public.order_items i where i.order_id = p_id and i.product_id = pr.id;
    end if;
    update public.orders set fulfillment_status = 'cancelado', status = 'cancelado', stock_deducted = false where id = p_id;
  else
    update public.orders set fulfillment_status = p_status,
      status = case when p_status = 'entregue' then 'entregue' else status end
    where id = p_id;
  end if;
end $$;

-- Marcar pago/não pago (Pix ou Cartão). Lança/remove a receita no
-- financeiro sozinho.
create function public.set_order_paid(p_id uuid, p_paid boolean, p_payment_method text default 'Pix') returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  if p_payment_method not in ('Pix','Cartão') then raise exception 'Forma de pagamento inválida.'; end if;
  update public.orders set paid = p_paid, payment_method = case when p_paid then p_payment_method else payment_method end where id = p_id;
  if p_paid then
    insert into public.financial_entries(kind, category, payment_method, amount_cents, order_id)
    select 'receita', 'Vendas', p_payment_method, total_cents, id from public.orders where id = p_id
    on conflict (order_id) where kind = 'receita' do nothing;
  else
    delete from public.financial_entries where order_id = p_id and kind = 'receita';
  end if;
end $$;

-- Desconto no pedido (recalcula o total sozinho).
create function public.set_order_discount(p_id uuid, p_discount_cents int) returns void
language plpgsql security definer set search_path=public as $$
declare sub int; fee int;
begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  if p_discount_cents < 0 then raise exception 'Desconto inválido.'; end if;
  select coalesce(sum(qty*unit_price_cents),0) into sub from public.order_items where order_id = p_id;
  select delivery_fee_cents into fee from public.orders where id = p_id;
  if fee is null then raise exception 'Pedido não encontrado.'; end if;
  if p_discount_cents > sub then raise exception 'Desconto maior que o subtotal.'; end if;
  update public.orders set discount_cents = p_discount_cents, total_cents = sub - p_discount_cents + fee where id = p_id;
end $$;

-- Taxa de entrega (existe no banco, sem uso no admin-v2 por ora).
create function public.set_delivery_fee(p_id uuid, p_fee_cents int) returns void
language plpgsql security definer set search_path=public as $$
declare sub int;
begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  if p_fee_cents < 0 then raise exception 'Taxa inválida.'; end if;
  select coalesce(sum(qty*unit_price_cents),0) into sub from public.order_items where order_id = p_id;
  update public.orders set delivery_fee_cents = p_fee_cents,
    total_cents = sub - discount_cents + p_fee_cents where id = p_id;
end $$;

-- Nome do entregador (campo livre, sem cadastro de equipe).
create function public.set_courier(p_id uuid, p_name text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  update public.orders set courier_name = nullif(trim(p_name),'') where id = p_id;
end $$;

-- Abrir/fechar o cardápio (o cliente vê "fechado" e não consegue pedir).
create function public.set_menu_status(p_status text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
  if p_status not in ('aberto','fechado') then raise exception 'Status inválido.'; end if;
  insert into public.settings(key, value) values ('menu_status', to_jsonb(p_status))
  on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

revoke all on function public.accept_order(uuid), public.set_fulfillment_status(uuid,text),
  public.set_order_paid(uuid,boolean,text), public.set_order_discount(uuid,int),
  public.set_delivery_fee(uuid,int), public.set_courier(uuid,text), public.set_menu_status(text)
  from public, anon, authenticated;
grant execute on function public.accept_order(uuid), public.set_fulfillment_status(uuid,text),
  public.set_order_paid(uuid,boolean,text), public.set_order_discount(uuid,int),
  public.set_delivery_fee(uuid,int), public.set_courier(uuid,text), public.set_menu_status(text)
  to authenticated;
