-- Terzo difetto nelle RPC clip: doppio conteggio.
--
-- `clip_comments.like_count` e `clips.comments` sono gia' mantenuti da trigger
-- AFTER su clip_comment_likes e clip_comments (clip_comment_like_count_inc/dec,
-- clip_comments_clip_count_inc/dec), che aggiornano anche `updated_at`. Le RPC
-- facevano la stessa UPDATE una seconda volta: un like a un commento portava il
-- contatore a 2, un commento nuovo incrementava clips.comments di 2.
--
-- Non si vedeva perche' quelle RPC non erano mai arrivate a scrivere — prima per
-- l'ambiguita' degli overload, poi per i cast uuid mancanti. Ora che scrivono,
-- il doppio conteggio si vede eccome.
--
-- Si tiene il trigger e si toglie l'UPDATE dalla RPC: il trigger copre anche le
-- scritture che non passano dalla RPC, la RPC no.
--
-- clip_toggle_reaction resta com'e': su clip_reactions NON esiste un trigger che
-- mantenga clips.likes, quindi li' la RPC e' l'unico scrittore ed e' corretta
-- (verificato: like -> 1, unlike -> 0).

CREATE OR REPLACE FUNCTION public.clip_add_comment(p_clip_id text, p_content text, p_parent_comment_id text, p_comment_id text)
 RETURNS clip_comments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  inserted_row clip_comments;
  v_id uuid;
  v_parent uuid;
BEGIN
  v_id := CASE
    WHEN p_comment_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN p_comment_id::uuid
    ELSE gen_random_uuid()
  END;

  IF NULLIF(p_parent_comment_id, '') IS NOT NULL THEN
    IF p_parent_comment_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'clip_add_comment: p_parent_comment_id non e'' un uuid valido';
    END IF;
    v_parent := p_parent_comment_id::uuid;
  END IF;

  -- clips.comments e clip_comments.reply_count li aggiornano i trigger.
  INSERT INTO clip_comments (
    id, clip_id, user_id, parent_comment_id, content,
    like_count, reply_count, created_at, updated_at
  )
  VALUES (
    v_id, p_clip_id, auth.uid(), v_parent, p_content,
    0, 0, timezone('utc', now()), timezone('utc', now())
  )
  RETURNING * INTO inserted_row;

  RETURN inserted_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.clip_toggle_comment_like(p_comment_id text, p_like_id text)
 RETURNS TABLE(liked boolean, like_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  existing_id uuid;
  v_comment uuid;
  v_new_id uuid;
BEGIN
  IF p_comment_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'clip_toggle_comment_like: p_comment_id non e'' un uuid valido';
  END IF;
  v_comment := p_comment_id::uuid;

  SELECT l.id INTO existing_id
  FROM clip_comment_likes l
  WHERE l.comment_id = v_comment
    AND l.user_id = auth.uid();

  IF existing_id IS NULL THEN
    v_new_id := CASE
      WHEN p_like_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN p_like_id::uuid
      ELSE gen_random_uuid()
    END;

    -- Il contatore lo alza il trigger AFTER INSERT: qui si legge il risultato.
    INSERT INTO clip_comment_likes (id, comment_id, user_id, created_at)
    VALUES (v_new_id, v_comment, auth.uid(), timezone('utc', now()));

    RETURN QUERY SELECT TRUE,
                        (SELECT COALESCE(c.like_count, 0) FROM clip_comments c WHERE c.id = v_comment);
  ELSE
    DELETE FROM clip_comment_likes l WHERE l.id = existing_id;

    RETURN QUERY SELECT FALSE,
                        (SELECT COALESCE(c.like_count, 0) FROM clip_comments c WHERE c.id = v_comment);
  END IF;
END;
$function$;
