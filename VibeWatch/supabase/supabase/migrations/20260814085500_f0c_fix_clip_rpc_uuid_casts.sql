-- Le tre RPC clip superstiti erano rotte, non solo ambigue.
--
-- Il piano attribuiva il fatto che `clip_reactions` fosse a 0 righe da sempre
-- alla sola ambiguita' fra gli overload text e uuid, risolta in F0.c.2. Non era
-- tutto: le varianti TEXT — quelle che iOS invoca e che abbiamo tenuto —
-- inseriscono i parametri `text` dentro colonne `uuid` senza cast.
--
--   clip_reactions.id       uuid  <- p_reaction_id      text
--   clip_comments.id        uuid  <- p_comment_id       text
--   clip_comments.parent_comment_id uuid <- p_parent_comment_id text
--   clip_comment_likes.id   uuid  <- p_like_id          text
--   clip_comment_likes.comment_id uuid <- p_comment_id  text
--
-- PostgreSQL non ha un cast di assegnazione da text a uuid: ogni INSERT falliva
-- con "column is of type uuid but expression is of type text". Ecco perche'
-- clip_reactions e clip_comment_likes non hanno mai avuto una riga, e perche'
-- togliere l'ambiguita' da sola non avrebbe fatto funzionare i like.
--
-- iOS genera sempre `UUID().uuidString` (ClipCommentService.swift:64, 219, 404),
-- quindi il cast e' sempre valido. Per gli id di riga nuovi si accetta comunque
-- un valore malformato ripiegando su gen_random_uuid(): un id storto non deve
-- far fallire un like. Per gli id usati come chiave di ricerca no — li' un
-- valore non valido e' una chiamata sbagliata e va detto.

CREATE OR REPLACE FUNCTION public.clip_toggle_reaction(p_clip_id text, p_reaction_id text)
 RETURNS TABLE(liked boolean, like_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  existing_id uuid;
  v_new_id uuid;
BEGIN
  SELECT id INTO existing_id
  FROM clip_reactions
  WHERE clip_id = p_clip_id
    AND user_id = auth.uid()
    AND reaction_type = 'like';

  IF existing_id IS NULL THEN
    v_new_id := CASE
      WHEN p_reaction_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN p_reaction_id::uuid
      ELSE gen_random_uuid()
    END;

    INSERT INTO clip_reactions (id, clip_id, user_id, reaction_type, created_at, updated_at)
    VALUES (v_new_id, p_clip_id, auth.uid(), 'like', timezone('utc', now()), timezone('utc', now()));
    UPDATE clips
    SET likes = COALESCE(likes, 0) + 1,
        updated_at = timezone('utc', now())
    WHERE clip_id = p_clip_id;
    RETURN QUERY SELECT TRUE AS liked,
                        (SELECT COALESCE(likes, 0) FROM clips WHERE clip_id = p_clip_id) AS like_count;
  ELSE
    DELETE FROM clip_reactions WHERE id = existing_id;
    UPDATE clips
    SET likes = GREATEST(COALESCE(likes, 0) - 1, 0),
        updated_at = timezone('utc', now())
    WHERE clip_id = p_clip_id;
    RETURN QUERY SELECT FALSE AS liked,
                        (SELECT COALESCE(likes, 0) FROM clips WHERE clip_id = p_clip_id) AS like_count;
  END IF;
END;
$function$;

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

  -- Il padre e' una chiave di ricerca: una stringa fuori forma qui e' una
  -- risposta a un commento che non esiste, non un commento in cima al thread.
  IF NULLIF(p_parent_comment_id, '') IS NOT NULL THEN
    IF p_parent_comment_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'clip_add_comment: p_parent_comment_id non e'' un uuid valido';
    END IF;
    v_parent := p_parent_comment_id::uuid;
  END IF;

  INSERT INTO clip_comments (
    id, clip_id, user_id, parent_comment_id, content,
    like_count, reply_count, created_at, updated_at
  )
  VALUES (
    v_id, p_clip_id, auth.uid(), v_parent, p_content,
    0, 0, timezone('utc', now()), timezone('utc', now())
  )
  RETURNING * INTO inserted_row;

  UPDATE clips
  SET comments = COALESCE(comments, 0) + 1,
      updated_at = timezone('utc', now())
  WHERE clip_id = p_clip_id;

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

  SELECT id INTO existing_id
  FROM clip_comment_likes
  WHERE comment_id = v_comment
    AND user_id = auth.uid();

  IF existing_id IS NULL THEN
    v_new_id := CASE
      WHEN p_like_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN p_like_id::uuid
      ELSE gen_random_uuid()
    END;

    INSERT INTO clip_comment_likes (id, comment_id, user_id, created_at)
    VALUES (v_new_id, v_comment, auth.uid(), timezone('utc', now()));
    UPDATE clip_comments
    SET like_count = COALESCE(like_count, 0) + 1,
        updated_at = timezone('utc', now())
    WHERE id = v_comment;
    RETURN QUERY SELECT TRUE AS liked,
                        (SELECT COALESCE(like_count, 0) FROM clip_comments WHERE id = v_comment) AS like_count;
  ELSE
    DELETE FROM clip_comment_likes WHERE id = existing_id;
    UPDATE clip_comments
    SET like_count = GREATEST(COALESCE(like_count, 0) - 1, 0),
        updated_at = timezone('utc', now())
    WHERE id = v_comment;
    RETURN QUERY SELECT FALSE AS liked,
                        (SELECT COALESCE(like_count, 0) FROM clip_comments WHERE id = v_comment) AS like_count;
  END IF;
END;
$function$;
