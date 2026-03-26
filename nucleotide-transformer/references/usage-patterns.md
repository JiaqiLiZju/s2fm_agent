# Usage Patterns

Use this file for the grounded JAX inference workflow.

## Minimal inference example

```python
import haiku as hk
import jax
import jax.numpy as jnp
from nucleotide_transformer.pretrained import get_pretrained_model

parameters, forward_fn, tokenizer, config = get_pretrained_model(
    model_name="250M_multi_species_v2",
    embeddings_layers_to_save=(20,),
    attention_maps_to_save=((1, 4),),
    max_positions=32,
)
forward_fn = hk.transform(forward_fn)

sequences = [
    "ATTCCGATTCCGATTCCG",
    "ATTTCTCTCTCTCTCTGAGATCGATCGATCGAT",
]
batch = tokenizer.batch_tokenize(sequences)
tokens_str = [b[0] for b in batch]
tokens_ids = [b[1] for b in batch]
tokens = jnp.asarray(tokens_ids, dtype=jnp.int32)

random_key = jax.random.PRNGKey(0)
outs = forward_fn.apply(parameters, random_key, tokens)

print(outs["embeddings_20"].shape)
print(outs["attention_map_layer_1_number_4"].shape)
```

## Embeddings retrieval notes

- Transformer layers are 1-indexed.
- The docs note special behavior for final embeddings when a Roberta LM head is used.
- If the user requests "last-layer embeddings," mention that layer selection may map to the first LM-head layer norm rather than the literal last transformer block.

## Attention map notes

- Request attention maps with `attention_maps_to_save=((layer, head), ...)`.
- Read outputs from keys like `attention_map_layer_1_number_4`.
- Layer/head values must exist for the selected model.

## Padding and batch sizing notes

- `max_positions` controls fixed token padding length.
- Keep `max_positions` only as large as needed for the batch to reduce memory and compile cost.
- For mean pooling, remove CLS and mask padded positions before averaging.
- When discussing limits, use `num_tokens_inference` for counts including CLS.

## Usage boundary

- Keep examples in JAX and Haiku unless the user provides another grounded API source.
- Route notebook-specific requests to the linked inference notebook when implementation details are missing.
